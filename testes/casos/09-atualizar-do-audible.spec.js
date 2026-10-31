const { test, expect } = require("@playwright/test");
const { livro, abrir, livrosGravados } = require("../ajuda");

/**
 * "Atualizar do Kindle e do Audible" — a metade do Audible.
 *
 * O lado NATIVO (Mac) le o banco do Audible; o que estes casos trancam e a
 * metade que mora na pagina: QUEM entra, com que forma de linha, e o que a
 * janela diz quando uma das duas lojas nao esta disponivel.
 *
 * A regra de entrada e do usuario (31/10/2026): entra o que esta na biblioteca
 * do Audible dele, ou o que ja esta catalogado aqui e e gratuito pelo plano. O
 * pago que ele nao comprou fica de fora — ele decide se compra.
 *
 * A ponte e simulada de proposito, como no caso 08. No Mac de verdade ela
 * devolve a biblioteca do Audible; aqui devolve uma lista escolhida.
 */

const OUVIR = (asin) => `Ouvir: https://www.audible.com.br/pd/${asin}`;

/** Um produto como o lado nativo o entrega. */
function doAudible(titulo, extras = {}) {
  return {
    asin: "B0AUDIO0001", titulo, autores: ["Autor de Teste"], narradores: [],
    anoAudio: "2026", naBiblioteca: false, consumivel: true, paraSempre: false,
    ...extras,
  };
}

/**
 * Abre a pagina fingindo ser o app do Mac, com as lojas que o caso pedir.
 *
 * SO as bandeiras das lojas. Pondo __BIBLIOTECA_NATIVE__ a pagina passa a
 * esperar o lado nativo injetar a base, que no teste nunca vem, e ela fica
 * presa na tela de carregamento.
 */
async function abrirComLojas(page, base, { kindle = null, audible = null, aviso = "" } = {}) {
  await page.addInitScript(({ kindle, audible, aviso }) => {
    if (kindle !== null) window.__BIBLIOTECA_KINDLE__ = true;
    if (audible !== null) window.__BIBLIOTECA_AUDIBLE__ = true;
    if (aviso) window.__BIBLIOTECA_LOJAS_AVISO__ = aviso;
    window.__PEDIDOS__ = [];
    window.webkit = {
      messageHandlers: new Proxy({}, {
        get: (_, canal) => ({
          postMessage: (corpo) => {
            window.__PEDIDOS__.push({ canal, corpo });
            if (canal === "kindleListar") {
              setTimeout(() => window.kindleRecebeLista(kindle), 0);
            }
            if (canal === "audibleListar") {
              setTimeout(() => window.audibleRecebeLista(audible), 0);
            }
          },
        }),
      }),
    };
  }, { kindle, audible, aviso });
  return abrir(page, base);
}

const RESPOSTA = (livros) => ({ ok: true, livros });

test.describe("Atualizar do Audible", () => {
  test("o botao aparece com o Audible sozinho", async ({ page }) => {
    await abrirComLojas(page, [], { audible: RESPOSTA([]) });
    await expect(page.locator("#btn-lojas")).toBeVisible();
  });

  test("o botao NAO aparece sem loja nenhuma", async ({ page }) => {
    await abrir(page, []);
    await expect(page.locator("#btn-lojas")).toBeHidden();
  });

  test("audiolivro da sua biblioteca que a base nao tem entra com local, ano do audio e a mensagem", async ({ page }) => {
    await abrirComLojas(page, [], {
      audible: RESPOSTA([doAudible("So no Audible", { naBiblioteca: true, anoAudio: "2023" })]),
    });
    await page.click("#btn-lojas");
    await expect(page.locator("#modal-lojas")).toBeVisible();
    await page.click("#btn-lojas-confirmar");

    const base = await livrosGravados(page);
    expect(base).toHaveLength(1);
    expect(base[0].local).toBe("Audio book");
    expect(base[0].ano).toBe(2023);
    expect(base[0].comentarios).toBe(`A ser adquirido. | ${OUVIR("B0AUDIO0001")}`);
  });

  test("o que ja e SEU nao leva 'A ser adquirido.'", async ({ page }) => {
    await abrirComLojas(page, [], {
      audible: RESPOSTA([doAudible("Comprado", { naBiblioteca: true, paraSempre: true })]),
    });
    await page.click("#btn-lojas");
    await page.click("#btn-lojas-confirmar");

    const base = await livrosGravados(page);
    expect(base[0].comentarios).toBe(OUVIR("B0AUDIO0001"));
  });

  test("incluso no plano herda titulo, tema, pais e ano da linha IMPRESSA, nao da do Kindle", async ({ page }) => {
    await abrirComLojas(page, [
      livro("A Morte em Veneza", {
        autores: ["Thomas Mann"], temas: ["Literatura Alema"], ano: 1912,
        local: "Grupo de Literatura", pais: "DE", grupoLiteratura: ["Grupo"],
      }),
      livro("A Morte em Veneza", { temas: [], ano: 2018, local: "Kindle", pais: "" }),
    ], {
      audible: RESPOSTA([doAudible("A morte em Veneza", { anoAudio: "2026" })]),
    });
    await page.click("#btn-lojas");
    await page.click("#btn-lojas-confirmar");

    const base = await livrosGravados(page);
    expect(base).toHaveLength(3);
    const novo = base[2];
    expect(novo.titulo).toBe("A Morte em Veneza");     // a acentuacao e a da base
    expect(novo.autores).toEqual(["Thomas Mann"]);
    expect(novo.temas).toEqual(["Literatura Alema"]);
    expect(novo.ano).toBe(1912);                       // da OBRA, nao do audiolivro
    expect(novo.pais).toBe("DE");
    expect(novo.grupoLiteratura).toEqual(["Grupo"]);
    expect(novo.local).toBe("Audio book");
  });

  test("o PAGO que voce nao comprou nao entra", async ({ page }) => {
    await abrirComLojas(page, [livro("Pago")], {
      audible: RESPOSTA([doAudible("Pago", { consumivel: false, paraSempre: false })]),
    });
    await page.click("#btn-lojas");
    await expect(page.locator("#lojas-resumo")).toContainText("Nada a acrescentar");
    expect(await livrosGravados(page)).toHaveLength(1);
  });

  test("gratuito que NAO esta na base nem na sua biblioteca nao entra", async ({ page }) => {
    await abrirComLojas(page, [], {
      audible: RESPOSTA([doAudible("Nunca vi este", { consumivel: true })]),
    });
    await page.click("#btn-lojas");
    await expect(page.locator("#btn-lojas-confirmar")).toBeHidden();
    expect(await livrosGravados(page)).toHaveLength(0);
  });

  test("o que JA esta na base pelo ASIN nao reaparece", async ({ page }) => {
    await abrirComLojas(page, [
      livro("So no Audible", { local: "Audio book", comentarios: OUVIR("B0AUDIO0001") }),
    ], {
      audible: RESPOSTA([doAudible("So no Audible", { naBiblioteca: true })]),
    });
    await page.click("#btn-lojas");
    await expect(page.locator("#lojas-resumo")).toContainText("Nada a acrescentar");
    expect(await livrosGravados(page)).toHaveLength(1);
  });

  test("creditos e narrador vao para o comentario, cortados em tres", async ({ page }) => {
    await abrirComLojas(page, [], {
      audible: RESPOSTA([doAudible("Com elenco", {
        naBiblioteca: true, paraSempre: true,
        autores: ["Thomas Mann", "Um", "Dois", "Tres", "Quatro"],
        narradores: ["Voz"],
      })]),
    });
    await page.click("#btn-lojas");
    await page.click("#btn-lojas-confirmar");

    const base = await livrosGravados(page);
    expect(base[0].autores).toEqual(["Thomas Mann"]);
    expect(base[0].comentarios).toBe(
      `Outros creditos: Um, Dois, Tres e outros | Narrado por Voz | ${OUVIR("B0AUDIO0001")}`);
  });

  test("o link do Audible nao e lido como ASIN do Kindle", async ({ page }) => {
    // Se o `kindleAsinsDaBase()` enxergasse o endereco do Audible, um livro do
    // Kindle com o mesmo ASIN deixaria de entrar — e o contrario tambem.
    const erros = await abrirComLojas(page, [
      livro("Audiolivro ja cadastrado", { local: "Audio book", comentarios: OUVIR("B0AUDIO0001") }),
    ], {
      kindle: RESPOSTA([{ asin: "B0AUDIO0001", titulo: "Outro livro", autor: "Autor", ano: "2020", compra: "2026-10-01" }]),
      audible: RESPOSTA([doAudible("Audiolivro ja cadastrado", { naBiblioteca: true })]),
    });
    await page.click("#btn-lojas");
    await page.click("#btn-lojas-confirmar");

    const base = await livrosGravados(page);
    expect(base).toHaveLength(2);                 // so o do Kindle entrou
    expect(base[1].local).toBe("Kindle");
    expect(erros).toEqual([]);
  });

  test("as duas lojas cabem na MESMA janela", async ({ page }) => {
    await abrirComLojas(page, [], {
      kindle: RESPOSTA([{ asin: "B0KINDLE01", titulo: "Do Kindle", autor: "Autor", ano: "2020", compra: "2026-10-01" }]),
      audible: RESPOSTA([doAudible("Do Audible", { naBiblioteca: true })]),
    });
    await page.click("#btn-lojas");
    await expect(page.locator(".lojas-item")).toHaveCount(2);
    await page.click("#btn-lojas-confirmar");

    const locais = (await livrosGravados(page)).map(l => l.local).sort();
    expect(locais).toEqual(["Audio book", "Kindle"]);
  });

  test("a loja que falha diz o motivo, e a outra ainda entra", async ({ page }) => {
    await abrirComLojas(page, [], {
      kindle: RESPOSTA([{ asin: "B0KINDLE01", titulo: "Do Kindle", autor: "Autor", ano: "2020", compra: "2026-10-01" }]),
      audible: { ok: false, erro: "O Audible esta instalado, mas ainda nao entrou na sua conta." },
    });
    await page.click("#btn-lojas");
    await expect(page.locator("#lojas-aviso")).toContainText("ainda nao entrou na sua conta");
    await expect(page.locator(".lojas-item")).toHaveCount(1);
  });

  test("a loja que o Mac nao tem aparece como aviso, nao como silencio", async ({ page }) => {
    await abrirComLojas(page, [], {
      kindle: RESPOSTA([]),
      aviso: "Nao achei o aplicativo Audible neste Mac.",
    });
    await page.click("#btn-lojas");
    await expect(page.locator("#lojas-aviso")).toContainText("Nao achei o aplicativo Audible");
  });
});
