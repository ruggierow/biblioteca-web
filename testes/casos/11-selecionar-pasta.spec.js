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
 * CADA CASO RODA DUAS VEZES, uma por hospedeiro: o Windows (Tauri) e o Mac
 * (WKWebView). É a razão de o fluxo morar num lugar só, e isto é o que prova
 * que os dois caminham junto — se um deles divergir, metade da suíte reprova.
 *
 * OS HOSPEDEIROS AQUI SÃO DE MENTIRA, e é bom estar escrito: são dublês que
 * imitam o Rust (`tauri/src-tauri/src/lib.rs`) e o Swift
 * (`macos/.../BibliotecaWebApp.swift`). Provam a página, não eles. O Rust tem
 * os testes dele no próprio arquivo (`cargo test`, rodado na VM), nas duas
 * funções que mexem em arquivo e na travessia do roteiro do seletor.
 * Cada metade sozinha engana; as duas juntas cobrem.
 *
 * UMA DIFERENÇA ENTRE OS DOIS DUBLÊS, de propósito: o do Mac REINJETA os
 * livros depois de definir a pasta, porque o Swift de verdade faz isso. Então
 * é o lado Windows que prova que a própria página troca a lista no ramo A —
 * medido quebrando a linha e vendo reprovar.
 */

const NUVEM = "/Nuvem/Biblioteca", VAZIA = "/Vazia", VAZIA2 = "/Vazia2", QUEBRADA = "/Quebrada";

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
 * Abre a página fingindo ser um dos dois aplicativos.
 *
 * O dublê entra com `addInitScript`, ANTES de qualquer script da página: é o
 * que ela procura na primeira linha para decidir onde está. Entrar depois seria
 * medir o modo navegador com um enfeite por cima.
 */
async function abrirComo(page, hospedeiro, { disco, configurada, escolhas, livros = [] }) {
  const erros = [];
  page.on("pageerror", (e) => erros.push(String(e)));
  page.on("console", (m) => { if (m.type() === "error") erros.push(m.text()); });

  await page.addInitScript(
    ([hospedeiro, disco, configurada, escolhas, livros]) => {
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
      const TSV_DO_INTRUSO = "Intruso\tAutor de Teste\tTeste\t1999\t0\n";
      const base = (p) => p.split(/[\\/]/).filter(Boolean).pop() || p;
      const naPasta = () => F.disco[F.configurada] || {};

      // Olhar a pasta: o mesmo desfecho nos dois hospedeiros.
      const olhar = (caminho) => {
        const pasta = F.disco[caminho];
        const r = (tem, conteudo, erro) =>
          ({ nome: base(caminho), caminho, temArquivo: tem, conteudo, erro });
        if (!pasta) return r(false, "", "A pasta nao existe: " + caminho);
        const arq = pasta["biblioteca.txt"];
        if (arq === undefined) return r(false, "", "");
        if (arq === null) return r(true, "", "Acesso negado.");   // existe, nao le
        return r(true, arq, "");
      };

      // As quatro operacoes, normalizadas: e o que os casos conferem, e o que
      // os dois hospedeiros tem de oferecer com o MESMO desfecho.
      const servir = (op, args) => {
        F.chamadas.push({ op, args });
        switch (op) {
          case "escolher":
            return F.escolhas.length ? F.escolhas.shift() : "";
          case "olhar": {
            const r = olhar(args.caminho);
            // A corrida: o arquivo aparece DEPOIS de a pagina olhar.
            if (F.apareceDepoisDeOlhar === args.caminho) {
              F.disco[args.caminho]["biblioteca.txt"] = TSV_DO_INTRUSO;
              F.apareceDepoisDeOlhar = null;
            }
            return r;
          }
          case "definir":
            F.configurada = args.caminho;
            return args.caminho + "/biblioteca.txt";
          case "criar": {
            const pasta = F.disco[args.caminho];
            if (!pasta) throw "A pasta nao existe: " + args.caminho;
            if (pasta["biblioteca.txt"] !== undefined) throw "ja_existe";
            pasta["biblioteca.txt"] = args.conteudo;
            F.configurada = args.caminho;
            return args.caminho + "/biblioteca.txt";
          }
          default:
            return "";
        }
      };

      // O hospedeiro de verdade responde por IPC, nunca no mesmo instante.
      // Responder sem espera inverteria a ordem da partida -- o
      // DOMContentLoaded chegaria DEPOIS da carga e o aviso de "abrindo" ficaria
      // na tela para sempre. Um milissegundo basta para a ordem ser a real.
      const sono = () => new Promise((r) => setTimeout(r, 1));

      if (hospedeiro === "Windows") {
        window.__TAURI__ = { core: { invoke: async (cmd, args) => {
          await sono();
          switch (cmd) {
            case "carregar_tsv": return naPasta()["biblioteca.txt"] || "";
            case "info_do_arquivo":
              return JSON.stringify({ caminho: F.configurada + "/biblioteca.txt",
                modificado: "", configurada: F.configurada, usandoConfigurada: true });
            case "salvar_tsv": naPasta()["biblioteca.txt"] = args.conteudo; return;
            case "escolher_pasta": return servir("escolher", {});
            case "olhar_pasta": return JSON.stringify(servir("olhar", args));
            case "definir_pasta": return servir("definir", args);
            case "criar_na_pasta": return servir("criar", args);
            // diagnosticar, iniciar_sessao, carregar_fotos, carregar_removidas,
            // salvar_fotos e o que mais a pagina pedir na partida.
            default: return "";
          }
        } } };
        return;
      }

      // --- Mac ---------------------------------------------------------
      // O Swift rele e reinjeta os livros sozinho depois de definir a pasta,
      // que e o mesmo caminho do Recarregar. O duble faz o mesmo, senao estaria
      // medindo uma pagina que o aplicativo de verdade nao tem.
      const reinjetar = () => {
        const tsv = naPasta()["biblioteca.txt"] || "";
        try {
          biblioteca = parseTSV(tsv);                                  // eslint-disable-line
          localStorage.setItem("biblioteca-livros", JSON.stringify(biblioteca)); // eslint-disable-line
          atualizarTudo();                                             // eslint-disable-line
          atualizarBannerSync("ok");                                   // eslint-disable-line
          esconderCarregando();                                        // eslint-disable-line
        } catch (e) { console.error("reinjetar:", e); }
      };

      window.__BIBLIOTECA_NATIVE__ = true;
      window.__BIBLIOTECA_CAMINHO__ = F.configurada + "/biblioteca.txt";
      window.__BIBLIOTECA_KINDLE__ = false;
      window.__BIBLIOTECA_AUDIBLE__ = false;
      window.__BIBLIOTECA_LOJAS_AVISO__ = "";
      const canal = (nome) => ({
        postMessage: (corpo) => {
          if (nome !== "pasta") { F.chamadas.push({ op: "msg:" + nome, args: corpo }); return; }
          return (async () => {
            await sono();
            const { op } = corpo;
            const valor = servir(op, corpo);   // pode lancar: vira recusa da Promessa
            if (op === "definir" || op === "criar") reinjetar();
            return valor;
          })();
        },
      });
      window.webkit = { messageHandlers: new Proxy({}, { get: (_, nome) => canal(String(nome)) }) };
      // O Swift carrega na abertura; sem isto o aviso de "abrindo" fica eterno.
      window.addEventListener("load", () => setTimeout(reinjetar, 5));
    },
    [hospedeiro, disco, configurada, escolhas, livros],
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

/** O que a página pediu ao hospedeiro, só as operações. */
const operacoes = (page) => page.evaluate(() => window.__FALSO__.chamadas.map((c) => c.op));
const pedidos = (page, op) =>
  page.evaluate((o) => window.__FALSO__.chamadas.filter((x) => x.op === o), op);
const disco = (page) => page.evaluate(() => window.__FALSO__.disco);
const titulosNaTela = (page) =>
  page.$$eval("table tbody tr td:nth-child(2)", (tds) => tds.map((td) => td.textContent.trim()));

const BOTAO = "#btn-selecionar-pasta";
const CAIXA = "#modal-pasta";

test("no navegador comum o botão não aparece — lá não existe caminho de pasta", async ({ page }) => {
  await page.goto("/biblioteca.html");
  await expect(page.locator("#carregando")).toBeHidden();
  await expect(page.locator(BOTAO)).toBeHidden();
});

for (const HOSPEDEIRO of ["Windows", "Mac"]) {
  const abrir = (page, cfg) => abrirComo(page, HOSPEDEIRO, cfg);

  test.describe(`Selecionar pasta — ${HOSPEDEIRO}`, () => {
    test("o botão aparece, e em primeiro lugar na faixa", async ({ page }) => {
      const erros = await abrir(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Um") } }, configurada: NUVEM, escolhas: [],
      });
      await expect(page.locator(BOTAO)).toBeVisible();
      await expect(page.locator(BOTAO)).toHaveText("Selecionar pasta");
      // Primeiro da sua faixa: e o que a proposta pede, e o que faz dele a
      // porta de entrada em vez de mais um botao no meio dos onze.
      const primeiro = await page.$eval(BOTAO, (b) => b.parentElement.firstElementChild.id);
      expect(primeiro).toBe("btn-selecionar-pasta");
      expect(erros).toEqual([]);
    });

    test("a frase de ajuda fala do APP, não do navegador", async ({ page }) => {
      // "Vincule um arquivo..." e "navegadores sem suporte (Safari/Firefox)" são
      // falsas as duas aqui dentro: o arquivo já está ligado e não há navegador.
      // Apareciam assim mesmo nos dois aplicativos, inclusive nas figuras do
      // manual.
      await abrir(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Um") } }, configurada: NUVEM, escolhas: [],
      });
      const ajuda = page.locator("#ajuda-arquivo");
      await expect(ajuda).toContainText("Selecionar pasta");
      await expect(ajuda).not.toContainText("Safari");
      // E a troca de idioma não traz a frase velha de volta.
      await page.selectOption("#seletor-idioma", "en");
      await expect(ajuda).toContainText("Choose folder");
      await expect(ajuda).not.toContainText("Safari");
    });

    test.describe("ramo A — a pasta já tem uma biblioteca", () => {
      test("diz QUANTOS livros achou, e ao confirmar passa a usá-los", async ({ page }) => {
        const erros = await abrir(page, {
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
        expect((await pedidos(page, "definir")).map((p) => p.args.caminho)).toEqual([VAZIA2]);
        expect(await operacoes(page)).not.toContain("criar");
        // O arquivo de origem NÃO foi reescrito.
        expect((await disco(page))[VAZIA2]["biblioteca.txt"]).toBe(tsv("Dom Casmurro", "Memórias", "Esaú"));
        if (HOSPEDEIRO === "Mac") {
          // A faixa do Mac mostra o caminho que foi INJETADO na abertura. Trocar
          // de pasta sem atualizá-lo deixaria a faixa apontando para o arquivo
          // antigo com o aplicativo já gravando no novo -- o tipo de desencontro
          // que custou a biblioteca de seis dias antes no Windows, em 13/10.
          expect(await page.evaluate(() => window.__BIBLIOTECA_CAMINHO__))
            .toBe(VAZIA2 + "/biblioteca.txt");
        }
        expect(erros).toEqual([]);
      });

      test("um arquivo VAZIO conta zero — e a lista aberta não fica na tela", async ({ page }) => {
        // Sem isto, o Windows não trocaria a lista (`carregarDoTauri` só troca
        // quando lê algo) e os livros de antes ficariam na tela. A primeira
        // gravação os despejaria no arquivo DESTA pasta, que o usuário acabou
        // de ver vazio.
        const erros = await abrir(page, {
          disco: { [NUVEM]: { "biblioteca.txt": tsv("Antigo") }, [VAZIA]: { "biblioteca.txt": "" } },
          configurada: NUVEM, escolhas: [VAZIA],
        });
        expect(await titulosNaTela(page)).toEqual(["Antigo"]);
        await page.click(BOTAO);
        await expect(page.locator("#pasta-corpo")).toHaveText(
          'A pasta "Vazia" já tem um biblioteca.txt com 0 livro(s).');
        await page.click("#btn-pasta-confirmar");
        await expect.poll(() => titulosNaTela(page)).toEqual([]);
        // E o arquivo da pasta antiga continua intacto.
        expect((await disco(page))[NUVEM]["biblioteca.txt"]).toBe(tsv("Antigo"));
        expect(erros).toEqual([]);
      });

      test('"Escolher outra pasta" volta ao seletor', async ({ page }) => {
        await abrir(page, {
          disco: { [NUVEM]: {}, [VAZIA2]: { "biblioteca.txt": tsv("Outro") }, [VAZIA]: {} },
          configurada: NUVEM, escolhas: [VAZIA2, VAZIA],
        });
        await page.click(BOTAO);
        await expect(page.locator("#pasta-titulo")).toHaveText("Encontrei uma biblioteca nesta pasta");
        await page.click("#btn-pasta-recusar");          // quero outra
        // A segunda escolha estava vazia e nada aberto: criou lá, sem perguntar.
        await expect.poll(() => disco(page).then((d) => d[VAZIA]["biblioteca.txt"])).toBe("");
        expect((await pedidos(page, "escolher")).length).toBe(2);
      });

      test("fechar a caixa não muda nada", async ({ page }) => {
        await abrir(page, {
          disco: { [NUVEM]: { "biblioteca.txt": tsv("Antigo") }, [VAZIA2]: { "biblioteca.txt": tsv("Outro") } },
          configurada: NUVEM, escolhas: [VAZIA2],
        });
        await page.click(BOTAO);
        await page.click("#btn-pasta-fechar");
        await expect(page.locator(CAIXA)).not.toHaveClass(/active/);
        await sossegou(page);
        const ops = await operacoes(page);
        expect(ops).not.toContain("definir");
        expect(ops).not.toContain("criar");
        expect(await titulosNaTela(page)).toEqual(["Antigo"]);
      });
    });

    test("ramo B — pasta vazia e nada aberto: cria sem perguntar", async ({ page }) => {
      const erros = await abrir(page, {
        disco: { [NUVEM]: {}, [VAZIA]: {} }, configurada: NUVEM, escolhas: [VAZIA],
      });
      await page.click(BOTAO);
      // Nenhuma pergunta: o usuário acabou de escolher a pasta com essa finalidade.
      await expect(page.locator(CAIXA)).not.toHaveClass(/active/);
      await expect(page.locator("#toast")).toHaveText(
        'Criei o biblioteca.txt em "Vazia". Pode começar a cadastrar.');
      expect((await pedidos(page, "criar")).map((p) => [p.args.caminho, p.args.conteudo]))
        .toEqual([[VAZIA, ""]]);
      expect((await disco(page))[VAZIA]["biblioteca.txt"]).toBe("");
      expect(await titulosNaTela(page)).toEqual([]);
      expect(erros).toEqual([]);
    });

    test.describe("ramo C — há um biblioteca.txt e não dá para ler", () => {
      test("avisa, oferece outra pasta e NÃO escreve por cima", async ({ page }) => {
        const erros = await abrir(page, {
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
        await expect.poll(() => pedidos(page, "criar").then((c) => c.map((x) => x.args.caminho)))
          .toEqual([VAZIA]);
        // O arquivo ilegível continua lá, do jeito que estava.
        expect((await disco(page))[QUEBRADA]["biblioteca.txt"]).toBeNull();
        expect(erros).toEqual([]);
      });

      test("cancelar não escreve nada", async ({ page }) => {
        await abrir(page, {
          disco: { [NUVEM]: { "biblioteca.txt": tsv("Antigo") }, [QUEBRADA]: { "biblioteca.txt": null } },
          configurada: NUVEM, escolhas: [QUEBRADA],
        });
        await page.click(BOTAO);
        await expect(page.locator("#pasta-titulo")).toHaveText("Não consegui ler esta biblioteca");
        await page.click("#btn-pasta-fechar");
        await sossegou(page);
        expect(await operacoes(page)).not.toContain("criar");
        expect((await disco(page))[QUEBRADA]["biblioteca.txt"]).toBeNull();
      });
    });

    test.describe("ramo D — pasta vazia com livros abertos", () => {
      const abertos = [livro("Dom Casmurro"), livro("Memórias")];

      test('"Levar os 2 para esta pasta" grava os dois lá', async ({ page }) => {
        const erros = await abrir(page, {
          disco: { [NUVEM]: { "biblioteca.txt": tsv("Dom Casmurro", "Memórias") }, [VAZIA2]: {} },
          configurada: NUVEM, escolhas: [VAZIA2], livros: abertos,
        });
        await page.click(BOTAO);
        await expect(page.locator("#pasta-titulo")).toHaveText(
          "Esta pasta está vazia. O que fazer com os 2 livros que estão abertos?");
        await expect(page.locator("#btn-pasta-confirmar")).toHaveText("Levar os 2 para esta pasta");
        await expect(page.locator("#btn-pasta-recusar")).toHaveText("Criar uma biblioteca nova e vazia");
        await page.click("#btn-pasta-confirmar");

        await expect.poll(() => disco(page).then((d) => d[VAZIA2]["biblioteca.txt"]))
          .toContain("Dom Casmurro");
        expect((await disco(page))[VAZIA2]["biblioteca.txt"]).toContain("Memórias");
        expect((await titulosNaTela(page)).sort()).toEqual(["Dom Casmurro", "Memórias"]);
        expect(erros).toEqual([]);
      });

      test('"Criar uma biblioteca nova e vazia" deixa os livros ONDE ESTAVAM', async ({ page }) => {
        const erros = await abrir(page, {
          disco: { [NUVEM]: { "biblioteca.txt": tsv("Dom Casmurro", "Memórias") }, [VAZIA2]: {} },
          configurada: NUVEM, escolhas: [VAZIA2], livros: abertos,
        });
        await page.click(BOTAO);
        await page.click("#btn-pasta-recusar");

        await expect.poll(() => disco(page).then((d) => d[VAZIA2]["biblioteca.txt"])).toBe("");
        const d = await disco(page);
        expect(d[NUVEM]["biblioteca.txt"]).toBe(tsv("Dom Casmurro", "Memórias")); // a antiga intacta
        await expect.poll(() => titulosNaTela(page)).toEqual([]);
        expect(erros).toEqual([]);
      });

      test("fechar a caixa NÃO vale por 'nova e vazia' — aqui o 'não' escreve no disco", async ({ page }) => {
        await abrir(page, {
          disco: { [NUVEM]: { "biblioteca.txt": tsv("Dom Casmurro", "Memórias") }, [VAZIA2]: {} },
          configurada: NUVEM, escolhas: [VAZIA2], livros: abertos,
        });
        await page.click(BOTAO);
        await page.click("#btn-pasta-fechar");
        await sossegou(page);
        expect(await operacoes(page)).not.toContain("criar");
        expect((await disco(page))[VAZIA2]["biblioteca.txt"]).toBeUndefined();
        expect((await titulosNaTela(page)).sort()).toEqual(["Dom Casmurro", "Memórias"]);
      });
    });

    test("cancelar o seletor não faz nada, e não é erro", async ({ page }) => {
      const erros = await abrir(page, {
        disco: { [NUVEM]: { "biblioteca.txt": tsv("Antigo") } },
        configurada: NUVEM, escolhas: [""],   // "" = fechou o seletor
      });
      await page.click(BOTAO);
      await sossegou(page);
      await expect(page.locator(CAIXA)).not.toHaveClass(/active/);
      const ops = await operacoes(page);
      expect(ops).not.toContain("olhar");
      expect(ops).not.toContain("definir");
      expect(ops).not.toContain("criar");
      expect(await titulosNaTela(page)).toEqual(["Antigo"]);
      expect(erros).toEqual([]);
    });

    test("o arquivo que apareceu entre o olhar e o criar é USADO, não sobrescrito", async ({ page }) => {
      // Provedores de nuvem baixam renomeando para "biblioteca (1).txt" e
      // depois trocam os dois. Se a criação passasse por cima, a biblioteca que
      // acabou de chegar seria zerada.
      const erros = await abrir(page, {
        disco: { [NUVEM]: {}, [VAZIA]: {} }, configurada: NUVEM, escolhas: [VAZIA, VAZIA],
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
      const erros = await abrir(page, {
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
}

test.describe("A janela de boas-vindas", () => {
  /** A página sem nenhum livro e sem hospedeiro: é quando ela aparecia. */
  const primeiraVez = async (page, antes) => {
    await page.addInitScript(antes);
    await page.goto("/biblioteca.html");
    await expect(page.locator("#carregando")).toBeHidden();
  };

  test("no navegador comum continua aparecendo", async ({ page }) => {
    await primeiraVez(page, () => { localStorage.clear(); });
    await expect(page.locator("#modal-primeiro-uso")).toBeVisible();
  });

  test("no Mac NÃO aparece mais — a opção recomendada ali era um beco sem saída", async ({ page }) => {
    // Ela chamava o `btn-vincular`, que depende do `showDirectoryPicker` do
    // navegador; o WKWebView não o tem, e nada acontecia.
    await primeiraVez(page, () => {
      localStorage.clear();
      window.__BIBLIOTECA_NATIVE__ = true;
      window.__BIBLIOTECA_CAMINHO__ = "/Nuvem/Biblioteca/biblioteca.txt";
      window.webkit = { messageHandlers: new Proxy({}, { get: () => ({ postMessage: () => {} }) }) };
      window.addEventListener("load", () => setTimeout(() => {
        try { esconderCarregando(); } catch (e) { /* a pagina ainda nao carregou */ }
      }, 5));
    });
    await expect(page.locator("#modal-primeiro-uso")).toBeHidden();
  });
});
