const { test, expect } = require("@playwright/test");
const { livro, abrir } = require("../ajuda");

/**
 * O mapa mostra a FORMA do acervo; a lista ao lado mostra os NOMES.
 *
 * A divisao nao e enfeite: com 38 paises, a Europa vira um aglomerado de
 * poucos pixels e os rotulos se empilham — na primeira versao, "CLARUY" era
 * Chile, Argentina e Uruguai sobrepostos. Entao a bolha so leva sigla quando o
 * nome cabe dentro dela, e quem nomeia o resto e a lista.
 */
const base = [
  livro("Um do Brasil", { pais: "BR" }),
  livro("Outro do Brasil", { pais: "BR" }),
  livro("Terceiro do Brasil", { pais: "BR" }),
  livro("Um do Japao", { pais: "JP" }),
  livro("Sem pais nenhum"),
];

async function abrirComMapa(page, livros = base) {
  await abrir(page, livros);
  await page.evaluate(() => { document.getElementById("secao-mapa").open = true; });
}

test.describe("Mapa por pais", () => {
  test("uma bolha e um item de lista por pais distinto", async ({ page }) => {
    await abrirComMapa(page);
    expect(await page.locator("#mapa-svg [data-pais]").count()).toBe(2);
    expect(await page.locator("#mapa-lista [data-pais]").count()).toBe(2);
  });

  test("a bolha maior e a do pais com mais livros", async ({ page }) => {
    await abrirComMapa(page);
    const raios = await page.evaluate(() =>
      Object.fromEntries([...document.querySelectorAll("#mapa-svg circle[data-pais]")]
        .map((c) => [c.dataset.pais, parseFloat(c.getAttribute("r"))])));
    expect(raios.BR).toBeGreaterThan(raios.JP);
  });

  test("clicar numa bolha filtra a lista de livros", async ({ page }) => {
    await abrirComMapa(page);
    await page.click('#mapa-svg circle[data-pais="JP"]');
    const titulos = await page.$$eval("table tbody tr td:nth-child(2)", (t) => t.map((x) => x.textContent.trim()));
    expect(titulos).toEqual(["Um do Japao"]);
  });

  test("clicar de novo no mesmo pais desfaz o filtro", async ({ page }) => {
    await abrirComMapa(page);
    await page.click('#mapa-lista [data-pais="BR"]');
    expect(await page.locator("table tbody tr").count()).toBe(3);
    await page.click('#mapa-lista [data-pais="BR"]');
    expect(await page.locator("table tbody tr").count()).toBe(5);
  });

  // O filtro funcionava e NADA na tela dizia qual pais estava ativo: o
  // executarPesquisa redesenha a tabela, nao o mapa. Este caso tranca isso.
  test("o pais ativo aparece na tela: bolha, item e chip", async ({ page }) => {
    await abrirComMapa(page);
    await page.click('#mapa-lista [data-pais="BR"]');
    expect(await page.locator("#mapa-svg .bolha.ativa").count()).toBe(1);
    expect(await page.locator("#mapa-lista .ativo").count()).toBe(1);
    await expect(page.locator(".mapa-chip")).toContainText("Brasil");
  });

  test("o X do chip volta a mostrar todos", async ({ page }) => {
    await abrirComMapa(page);
    await page.click('#mapa-lista [data-pais="BR"]');
    await page.click("#mapa-limpar");
    expect(await page.locator("table tbody tr").count()).toBe(5);
    expect(await page.locator(".mapa-chip").count()).toBe(0);
  });

  test("o mundo e desenhado por baixo das bolhas", async ({ page }) => {
    await abrirComMapa(page);
    // o fundo mais os paises SEM livro ficam com o tom neutro; os COM livro
    // ganham um tom proprio — aqui, Brasil e Japao.
    expect(await page.locator("#mapa-svg .terra").count()).toBeGreaterThan(10);
    expect(await page.locator("#mapa-svg .terra-minha").count()).toBe(2);
    // e o contorno vem ANTES das bolhas, senao elas ficariam por baixo
    const ordem = await page.evaluate(() =>
      [...document.querySelectorAll("#mapa-svg > *")].map((e) => e.tagName.toLowerCase()));
    expect(ordem.indexOf("g")).toBeGreaterThan(ordem.lastIndexOf("path"));
  });

  // Pais pequeno com poucos livros virava bolha quase invisivel — e o que nao se
  // acerta com o ponteiro nao se le. Dai o raio minimo.
  test("mesmo um pais com UM livro tem bolha que da para acertar", async ({ page }) => {
    await abrirComMapa(page, [
      livro("Muitos 1", { pais: "BR" }), livro("Muitos 2", { pais: "BR" }),
      livro("Muitos 3", { pais: "BR" }), livro("Muitos 4", { pais: "BR" }),
      livro("Um so", { pais: "PT" }),
    ]);
    const r = await page.evaluate(() =>
      parseFloat(document.querySelector('#mapa-svg circle[data-pais="PT"]').getAttribute("r")));
    expect(r).toBeGreaterThanOrEqual(2.6);
  });

  // A lupa nao pode depender so de `:hover`: assim ela nao e testavel, e nao
  // serve ao teclado nem ao toque.
  test("a lupa cresce a bolha e revela o nome", async ({ page }) => {
    await abrirComMapa(page);
    const antes = await page.evaluate(() => {
      const c = document.querySelector('#mapa-svg circle[data-pais="JP"]');
      return getComputedStyle(c.closest(".ponto").querySelector(".rotulo-lupa")).opacity;
    });
    expect(antes).toBe("0");
    const depois = await page.evaluate(() => {
      const c = document.querySelector('#mapa-svg circle[data-pais="JP"]');
      c.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
      const g = c.closest(".ponto");
      return { destacado: g.classList.contains("destacado"),
               texto: g.querySelector(".rotulo-lupa").textContent };
    });
    expect(depois.destacado).toBe(true);
    expect(depois.texto).toContain("Jap\u00e3o");   // a grafia e a dos celulares
  });

  // Em SVG nao ha z-index: vale a ordem no documento. Sem trazer para a frente,
  // a bolha ampliada some por baixo das vizinhas em regiao cheia — foi o que o
  // usuario viu na Europa.
  test("a bolha destacada vai para a FRENTE das vizinhas", async ({ page }) => {
    // As bolhas sao desenhadas da maior para a menor, para que uma grande nunca
    // tape uma pequena. Entao, para provar que o destaque traz para a frente, o
    // alvo precisa estar NO MEIO — se for o ultimo, ja estaria na frente.
    await abrirComMapa(page, [
      livro("B1", { pais: "BR" }), livro("B2", { pais: "BR" }), livro("B3", { pais: "BR" }),
      livro("J1", { pais: "JP" }), livro("J2", { pais: "JP" }),
      livro("P1", { pais: "PT" }),
    ]);
    const posicaoDoJP = async () => page.evaluate(() => {
      const g = document.querySelector('#mapa-svg circle[data-pais="JP"]').closest(".ponto");
      return [...g.parentNode.querySelectorAll(".ponto")].indexOf(g);
    });
    const antes = await posicaoDoJP();
    await page.evaluate(() => document.querySelector('#mapa-svg circle[data-pais="JP"]')
      .dispatchEvent(new MouseEvent("mouseover", { bubbles: true })));
    const depois = await posicaoDoJP();
    const total = await page.locator("#mapa-svg .ponto").count();
    expect(antes).toBeLessThan(total - 1);   // nao era o ultimo
    expect(depois).toBe(total - 1);          // agora e
  });

  test("passar o mouse no nome da lista acende a bolha no mapa", async ({ page }) => {
    await abrirComMapa(page);
    await page.hover('#mapa-lista [data-pais="JP"]');
    expect(await page.locator('#mapa-svg circle[data-pais="JP"]').evaluate(
      (c) => c.closest(".ponto").classList.contains("destacado"))).toBe(true);
  });

  test("conta quantos livros ainda estao sem pais", async ({ page }) => {
    await abrirComMapa(page);
    await expect(page.locator("#mapa-rodape")).toContainText("1 ainda sem pais");
  });

  // Um codigo sem posicao no mapa nao pode sumir calado: ele some do desenho,
  // mas o rodape avisa. Senao o livro existiria na base e em lugar nenhum.
  test("pais sem posicao conhecida e DENUNCIADO, nao escondido", async ({ page }) => {
    await abrirComMapa(page, [livro("De um pais que eu nao mapeei", { pais: "ZZ" })]);
    expect(await page.locator("#mapa-svg [data-pais]").count()).toBe(0);
    await expect(page.locator("#mapa-rodape")).toContainText("ZZ");
  });
});
