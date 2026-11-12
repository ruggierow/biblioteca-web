const { test, expect } = require("@playwright/test");

/**
 * "Selecionar pasta" — os quatro ramos do primeiro acesso.
 *
 * O QUE ESTES CASOS MEDEM: a decisão da página. Quando a pasta já tem uma
 * biblioteca, quando está vazia, quando o arquivo não se lê, e o que acontece
 * com os livros que já estão abertos. **São todos caminhos de escrita**, e o
 * erro aqui custa a biblioteca de alguém — por isso cada caso confere o que
 * foi para o "disco", não só o que apareceu na tela.
 *
 * O HOSPEDEIRO AQUI É DE MENTIRA, e é bom estar escrito: `window.__TAURI__`
 * abaixo é um dublê que imita o Rust de `motor-web/tauri/src-tauri/src/lib.rs`.
 * Ele prova a página, não o Rust. O Rust tem os testes dele no próprio arquivo
 * (`cargo test`), nas duas funções que mexem em arquivo: `olhar` e
 * `criar_arquivo_na_pasta`. Cada metade sozinha engana; as duas juntas cobrem.
 *
 * O dublê é fiel em três pontos que importam:
 *   - `escolher_pasta` devolve "" quando se cancela (cancelar não é erro);
 *   - `olhar_pasta` devolve o CONTEÚDO, e quem conta os livros é a `parseTSV`
 *     da própria página — um segundo contador divergiria;
 *   - `criar_na_pasta` NUNCA sobrescreve: recusa com `ja_existe`.
 */

const NUVEM = "C:\\Nuvem\\Biblioteca";
const VAZIA = "C:\\Vazia";
const VAZIA2 = "C:\\Vazia2";
const QUEBRADA = "C:\\Quebrada";

function tsv(...titulos) {
  return titulos.map((t) => `${t}\tAutor de Teste\tTeste\t2020\t0`).join("\n") + "\n";
}

/** Um livro no formato que a página guarda no localStorage. */
function livro(titulo) {
  return {
    titulo, autores: ["Autor de Teste"], temas: ["Teste"], ano: 2020,
    emprestado: false, comentarios: "", local: "", grupoLiteratura: [],
  };
}

/**
 * Abre a página fingindo ser o app do Windows.
 *
 * O dublê entra com `addInitScript`, ANTES de qualquer script da página: é o
 * que a página procura na primeira linha para decidir se está no Tauri. Entrar
 * depois seria medir o modo navegador com um enfeite por cima.
 */
async function abrirComoWindows(page, { disco, configurada, escolhas, livros = [] }) {
  const erros = [];
  page.on("pageerror", (e) => erros.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error") erros.push(m.text()); });

  await page.addInitScript(
    ([disco, configurada, escolhas, livros]) => {
      localStorage.setItem("biblioteca-livros", JSON.stringify(livros));
      localStorage.setItem("biblioteca-fotos", "{}");
      localStorage.setItem("biblioteca-idioma", "pt");

      const F = (window.__FALSO__ = {
        disco: JSON.parse(JSON.stringify(disco)),  // pasta -> {arquivo: texto|null}
        configurada,
        escolhas: escolhas.slice(),
        chamadas: [],
        apareceDepoisDeOlhar: null,
      });
      const base = (p) => p.split(/[\\/]/).filter(Boolean).pop() || p;
      const olhar = (caminho) => {
        const pasta = F.disco[caminho];
        const resposta = (tem, conteudo, erro) =>
          JSON.stringify({ nome: base(caminho), caminho, temArquivo: tem, conteudo, erro });
        if (!pasta) return resposta(false, "", "A pasta não existe: " + caminho);
        const arq = pasta["biblioteca.txt"];
        if (arq === undefined) return resposta(false, "", "");
        if (arq === null) return resposta(true, "", "Acesso negado.");  // existe, não lê
        return resposta(true, arq, "");
      };

      // O hospedeiro de verdade responde por IPC, nunca no mesmo instante.
      // Responder sem espera inverteria a ordem da partida -- o
      // DOMContentLoaded chegaria DEPOIS da carga e o aviso de "abrindo" ficaria
      // na tela para sempre. Um milissegundo basta para a ordem ser a real.
      const sono = () => new Promise((r) => setTimeout(r, 1));

      window.__TAURI__ = {
        core: {
          invoke: async (cmd, args) => {
            F.chamadas.push({ cmd, args });
            await sono();
            const atual = () => F.disco[F.configurada] || {};
            switch (cmd) {
              case "carregar_tsv": return atual()["biblioteca.txt"] || "";
              case "info_do_arquivo":
                return JSON.stringify({
                  caminho: F.configurada + "\\biblioteca.txt",
                  modificado: "", configurada: F.configurada, usandoConfigurada: true,
                });
              case "salvar_tsv":
                atual()["biblioteca.txt"] = args.conteudo;
                return;
              case "escolher_pasta":
                return F.escolhas.length ? F.escolhas.shift() : "";
              case "olhar_pasta": {
                const r = olhar(args.caminho);
                // A corrida: o arquivo aparece DEPOIS de a pagina olhar.
                if (F.apareceDepoisDeOlhar === args.caminho) {
                  F.disco[args.caminho]["biblioteca.txt"] = tsvDoIntruso;
                  F.apareceDepoisDeOlhar = null;
                }
                return r;
              }
              case "definir_pasta":
                F.configurada = args.caminho;
                return args.caminho;
              case "criar_na_pasta": {
                const pasta = F.disco[args.caminho];
                if (!pasta) throw "A pasta nao existe: " + args.caminho;
                if (pasta["biblioteca.txt"] !== undefined) throw "ja_existe";
                pasta["biblioteca.txt"] = args.conteudo;
                F.configurada = args.caminho;
                return args.caminho + "\\biblioteca.txt";
              }
              // diagnosticar, iniciar_sessao, carregar_fotos, carregar_removidas,
              // salvar_fotos e o que mais a pagina pedir na partida.
              default: return "";
            }
          },
        },
      };
      const tsvDoIntruso = "Intruso\tAutor de Teste\tTeste\t1999\t0\n";
    },
    [disco, configurada, escolhas, livros],
  );

  await page.goto("/biblioteca.html");
  await expect(page.locator("#carregando")).toBeHidden();
  return erros;
}

/**
 * Espera o fluxo terminar.
 *
 * Clicar num botão da caixa a fecha NA HORA, mas o que vem depois — vincular,
 * criar, reler — é assíncrono. Nas afirmações do que TEM de acontecer usamos
 * `expect.poll`, que reconsulta até o estado chegar. Nas do que NÃO pode
 * acontecer isso não serve (passariam antes de a coisa acontecer): ali
 * esperamos um instante e só então olhamos.
 */
const sossegou = (page) => page.waitForTimeout(80);

/** O que a página pediu ao hospedeiro, só os comandos. */
const comandos = (page) =>
  page.evaluate(() => window.__FALSO__.chamadas.map((c) => c.cmd));
const chamada = (page, cmd) =>
  page.evaluate((c) => window.__FALSO__.chamadas.filter((x) => x.cmd === c), cmd);
const disco = (page) => page.evaluate(() => window.__FALSO__.disco);
const titulosNaTela = (page) =>
  page.$$eval("table tbody tr td:nth-child(2)", (tds) => tds.map((td) => td.textContent.trim()));

const BOTAO = "#btn-selecionar-pasta";
const CAIXA = "#modal-pasta";

test.describe("Selecionar pasta", () => {
  test("o botão aparece no app do Windows", async ({ page }) => {
    const erros = await abrirComoWindows(page, {
      disco: { [NUVEM]: { "biblioteca.txt": tsv("Um") } },
      configurada: NUVEM, escolhas: [],
    });
    await expect(page.locator(BOTAO)).toBeVisible();
    await expect(page.locator(BOTAO)).toHaveText("Selecionar pasta");
    expect(erros).toEqual([]);
  });

  test("no navegador comum o botão não aparece — lá não existe caminho de pasta", async ({ page }) => {
    await page.goto("/biblioteca.html");
    await expect(page.locator("#carregando")).toBeHidden();
    await expect(page.locator(BOTAO)).toBeHidden();
  });

  test.describe("ramo A — a pasta já tem uma biblioteca", () => {
    test("diz QUANTOS livros achou, e ao confirmar passa a usá-los", async ({ page }) => {
      const erros = await abrirComoWindows(page, {
        disco: {
          [NUVEM]: { "biblioteca.txt": tsv("Antigo") },
          [VAZIA2]: { "biblioteca.txt": tsv("Dom Casmurro", "Memórias", "Esaú") },
        },
        configurada: NUVEM, escolhas: [VAZIA2],
      });
      await page.click(BOTAO);
      await expect(page.locator("#pasta-titulo")).toHaveText("Encontrei uma biblioteca nesta pasta");
      await expect(page.locator("#pasta-corpo")).toHaveText(
        'A pasta "Vazia2" já tem um biblioteca.txt com 3 livro(s).');
      await page.click("#btn-pasta-confirmar");
      await expect(page.locator(CAIXA)).not.toHaveClass(/active/);

      await expect.poll(() => titulosNaTela(page).then((t) => t.sort()))
        .toEqual(["Dom Casmurro", "Esaú", "Memórias"]);
      expect(await chamada(page, "definir_pasta")).toEqual([{ cmd: "definir_pasta", args: { caminho: VAZIA2 } }]);
      expect(await comandos(page)).not.toContain("criar_na_pasta");
      // O arquivo de origem NÃO foi reescrito.
      expect((await disco(page))[VAZIA2]["biblioteca.txt"]).toBe(tsv("Dom Casmurro", "Memórias", "Esaú"));
      expect(erros).toEqual([]);
    });

    test("um arquivo VAZIO conta zero — e a lista aberta não fica na tela", async ({ page }) => {
      // Sem isto, `carregarDoTauri` não trocaria a lista (só troca quando lê
      // algo) e os livros de antes ficariam na tela. A primeira gravação os
      // despejaria no arquivo DESTA pasta, que o usuário acabou de ver vazio.
      const erros = await abrirComoWindows(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Antigo") }, [VAZIA]: { "biblioteca.txt": "" } },
        configurada: NUVEM, escolhas: [VAZIA],
      });
      expect(await titulosNaTela(page)).toEqual(["Antigo"]);
      await page.click(BOTAO);
      await expect(page.locator("#pasta-corpo")).toHaveText(
        'A pasta "Vazia" já tem um biblioteca.txt com 0 livro(s).');
      await page.click("#btn-pasta-confirmar");
      await expect(page.locator(CAIXA)).not.toHaveClass(/active/);
      await expect.poll(() => titulosNaTela(page)).toEqual([]);
      // E o arquivo da pasta antiga continua intacto.
      expect((await disco(page))[NUVEM]["biblioteca.txt"]).toBe(tsv("Antigo"));
      expect(erros).toEqual([]);
    });

    test('"Escolher outra pasta" volta ao seletor', async ({ page }) => {
      await abrirComoWindows(page, {
        disco: { [NUVEM]: {}, [VAZIA2]: { "biblioteca.txt": tsv("Outro") }, [VAZIA]: {} },
        configurada: NUVEM, escolhas: [VAZIA2, VAZIA],
      });
      await page.click(BOTAO);
      await expect(page.locator("#pasta-titulo")).toHaveText("Encontrei uma biblioteca nesta pasta");
      await page.click("#btn-pasta-recusar");          // quero outra
      // A segunda escolha estava vazia e nada aberto: criou lá, sem perguntar.
      await expect.poll(() => disco(page).then((d) => d[VAZIA]["biblioteca.txt"])).toBe("");
      expect((await chamada(page, "escolher_pasta")).length).toBe(2);
    });

    test("fechar a caixa não muda nada", async ({ page }) => {
      await abrirComoWindows(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Antigo") }, [VAZIA2]: { "biblioteca.txt": tsv("Outro") } },
        configurada: NUVEM, escolhas: [VAZIA2],
      });
      await page.click(BOTAO);
      await page.click("#btn-pasta-fechar");
      await expect(page.locator(CAIXA)).not.toHaveClass(/active/);
      await sossegou(page);
      const pedidos = await comandos(page);
      expect(pedidos).not.toContain("definir_pasta");
      expect(pedidos).not.toContain("criar_na_pasta");
      expect(await titulosNaTela(page)).toEqual(["Antigo"]);
    });
  });

  test("ramo B — pasta vazia e nada aberto: cria sem perguntar", async ({ page }) => {
    const erros = await abrirComoWindows(page, {
      disco: { [NUVEM]: {}, [VAZIA]: {} },
      configurada: NUVEM, escolhas: [VAZIA],
    });
    await page.click(BOTAO);
    // Nenhuma pergunta: o usuário acabou de escolher a pasta com essa finalidade.
    await expect(page.locator(CAIXA)).not.toHaveClass(/active/);
    await expect(page.locator("#toast")).toHaveText(
      'Criei o biblioteca.txt em "Vazia". Pode começar a cadastrar.');
    expect(await chamada(page, "criar_na_pasta")).toEqual(
      [{ cmd: "criar_na_pasta", args: { caminho: VAZIA, conteudo: "" } }]);
    expect((await disco(page))[VAZIA]["biblioteca.txt"]).toBe("");
    expect(await titulosNaTela(page)).toEqual([]);
    expect(erros).toEqual([]);
  });

  test.describe("ramo C — há um biblioteca.txt e não dá para ler", () => {
    test("avisa, oferece outra pasta e NÃO escreve por cima", async ({ page }) => {
      const erros = await abrirComoWindows(page, {
        disco: { [NUVEM]: {}, [QUEBRADA]: { "biblioteca.txt": null }, [VAZIA]: {} },
        configurada: NUVEM, escolhas: [QUEBRADA, VAZIA],
      });
      await page.click(BOTAO);
      await expect(page.locator("#pasta-titulo")).toHaveText("Não consegui ler esta biblioteca");
      await expect(page.locator("#pasta-corpo")).toHaveText(
        "Há um biblioteca.txt nesta pasta, mas não consegui lê-lo: Acesso negado.");
      // Uma só saída, além de fechar: não existe "criar por cima".
      await expect(page.locator("#btn-pasta-confirmar")).toHaveText("Escolher outra pasta");
      await expect(page.locator("#btn-pasta-recusar")).toBeHidden();

      await page.click("#btn-pasta-confirmar");
      await expect.poll(() => chamada(page, "criar_na_pasta").then((c) => c.map((x) => x.args.caminho)))
        .toEqual([VAZIA]);
      // O arquivo ilegível continua lá, do jeito que estava.
      expect((await disco(page))[QUEBRADA]["biblioteca.txt"]).toBeNull();
      expect(erros).toEqual([]);
    });

    test("cancelar não escreve nada", async ({ page }) => {
      await abrirComoWindows(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Antigo") }, [QUEBRADA]: { "biblioteca.txt": null } },
        configurada: NUVEM, escolhas: [QUEBRADA],
      });
      await page.click(BOTAO);
      await expect(page.locator("#pasta-titulo")).toHaveText("Não consegui ler esta biblioteca");
      await page.click("#btn-pasta-fechar");
      await sossegou(page);
      expect(await comandos(page)).not.toContain("criar_na_pasta");
      expect((await disco(page))[QUEBRADA]["biblioteca.txt"]).toBeNull();
    });
  });

  test.describe("ramo D — pasta vazia com livros abertos", () => {
    const abertos = [livro("Dom Casmurro"), livro("Memórias")];

    test('"Levar os 2 para esta pasta" grava os dois lá', async ({ page }) => {
      const erros = await abrirComoWindows(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Dom Casmurro", "Memórias") }, [VAZIA2]: {} },
        configurada: NUVEM, escolhas: [VAZIA2], livros: abertos,
      });
      await page.click(BOTAO);
      await expect(page.locator("#pasta-titulo")).toHaveText(
        "Esta pasta está vazia. O que fazer com os 2 livros que estão abertos?");
      await expect(page.locator("#btn-pasta-confirmar")).toHaveText("Levar os 2 para esta pasta");
      await expect(page.locator("#btn-pasta-recusar")).toHaveText("Criar uma biblioteca nova e vazia");
      await page.click("#btn-pasta-confirmar");
      await expect(page.locator(CAIXA)).not.toHaveClass(/active/);

      await expect.poll(() => disco(page).then((d) => d[VAZIA2]["biblioteca.txt"]))
        .toContain("Dom Casmurro");
      expect((await disco(page))[VAZIA2]["biblioteca.txt"]).toContain("Memórias");
      expect((await titulosNaTela(page)).sort()).toEqual(["Dom Casmurro", "Memórias"]);
      expect(erros).toEqual([]);
    });

    test('"Criar uma biblioteca nova e vazia" deixa os livros ONDE ESTAVAM', async ({ page }) => {
      const erros = await abrirComoWindows(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Dom Casmurro", "Memórias") }, [VAZIA2]: {} },
        configurada: NUVEM, escolhas: [VAZIA2], livros: abertos,
      });
      await page.click(BOTAO);
      await page.click("#btn-pasta-recusar");
      await expect(page.locator(CAIXA)).not.toHaveClass(/active/);

      await expect.poll(() => disco(page).then((d) => d[VAZIA2]["biblioteca.txt"])).toBe("");
      const d = await disco(page);
      expect(d[NUVEM]["biblioteca.txt"]).toBe(tsv("Dom Casmurro", "Memórias")); // a antiga intacta
      await expect.poll(() => titulosNaTela(page)).toEqual([]);
      expect(erros).toEqual([]);
    });

    test("fechar a caixa NÃO vale por 'nova e vazia' — aqui o 'não' escreve no disco", async ({ page }) => {
      await abrirComoWindows(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Dom Casmurro", "Memórias") }, [VAZIA2]: {} },
        configurada: NUVEM, escolhas: [VAZIA2], livros: abertos,
      });
      await page.click(BOTAO);
      await page.click("#btn-pasta-fechar");
      await sossegou(page);
      expect(await comandos(page)).not.toContain("criar_na_pasta");
      expect((await disco(page))[VAZIA2]["biblioteca.txt"]).toBeUndefined();
      expect((await titulosNaTela(page)).sort()).toEqual(["Dom Casmurro", "Memórias"]);
    });
  });

  test("cancelar o seletor não faz nada, e não é erro", async ({ page }) => {
    const erros = await abrirComoWindows(page, {
      disco: { [NUVEM]: { "biblioteca.txt": tsv("Antigo") } },
      configurada: NUVEM, escolhas: [""],   // "" = fechou o seletor
    });
    await page.click(BOTAO);
    await sossegou(page);
    await expect(page.locator(CAIXA)).not.toHaveClass(/active/);
    const pedidos = await comandos(page);
    expect(pedidos).not.toContain("olhar_pasta");
    expect(pedidos).not.toContain("definir_pasta");
    expect(pedidos).not.toContain("criar_na_pasta");
    expect(await titulosNaTela(page)).toEqual(["Antigo"]);
    expect(erros).toEqual([]);
  });

  test("o arquivo que apareceu entre o olhar e o criar é USADO, não sobrescrito", async ({ page }) => {
    // Alguns provedores de nuvem baixam renomeando para "biblioteca (1).txt" e
    // depois trocam os dois. Se a criação passasse por cima, a biblioteca que
    // acabou de chegar seria zerada.
    const erros = await abrirComoWindows(page, {
      disco: { [NUVEM]: {}, [VAZIA]: {} },
      configurada: NUVEM, escolhas: [VAZIA, VAZIA],
    });
    await page.evaluate((p) => { window.__FALSO__.apareceDepoisDeOlhar = p; }, VAZIA);
    await page.click(BOTAO);
    // Volta ao ramo A, com a contagem do arquivo que apareceu.
    await expect(page.locator("#pasta-titulo")).toHaveText("Encontrei uma biblioteca nesta pasta");
    await expect(page.locator("#pasta-corpo")).toHaveText(
      'A pasta "Vazia" já tem um biblioteca.txt com 1 livro(s).');
    await page.click("#btn-pasta-confirmar");
    await expect.poll(() => titulosNaTela(page)).toEqual(["Intruso"]);
    expect((await disco(page))[VAZIA]["biblioteca.txt"]).toContain("Intruso");
    expect(erros).toEqual([]);
  });

  test("num aparelho em inglês, as palavras saem em inglês", async ({ page }) => {
    const erros = await abrirComoWindows(page, {
      disco: { [NUVEM]: {}, [VAZIA2]: { "biblioteca.txt": tsv("Um", "Dois") } },
      configurada: NUVEM, escolhas: [VAZIA2],
    });
    await page.selectOption("#seletor-idioma", "en");
    await expect(page.locator(BOTAO)).toHaveText("Choose folder");
    await page.click(BOTAO);
    await expect(page.locator("#pasta-titulo")).toHaveText("Found a library in this folder");
    await expect(page.locator("#pasta-corpo")).toHaveText(
      'The folder "Vazia2" already has a biblioteca.txt with 2 book(s).');
    await expect(page.locator("#btn-pasta-confirmar")).toHaveText("Use this library");
    await expect(page.locator("#btn-pasta-recusar")).toHaveText("Choose another folder");
    expect(erros).toEqual([]);
  });
});
