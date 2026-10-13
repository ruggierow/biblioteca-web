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
