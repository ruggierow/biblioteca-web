const { test, expect } = require("@playwright/test");
const { livro, abrir, titulosNaTela } = require("../ajuda");

test.describe("Lista e busca", () => {
  test("mostra os livros que estao na base", async ({ page }) => {
    const erros = await abrir(page, [livro("Dom Casmurro"), livro("Memorias Postumas")]);
    expect(await titulosNaTela(page)).toEqual(
      expect.arrayContaining(["Dom Casmurro", "Memorias Postumas"]),
    );
    expect(erros).toEqual([]);
  });

  test("filtra por titulo parcial", async ({ page }) => {
    await abrir(page, [livro("Dom Casmurro"), livro("Grande Sertao")]);
    await page.fill("#filtro-titulo", "casmurro");
    await page.click("#btn-pesquisar, button:has-text('Pesquisar')");
    const titulos = await titulosNaTela(page);
    expect(titulos).toEqual(["Dom Casmurro"]);
  });

  test("filtra por autor", async ({ page }) => {
    await abrir(page, [
      livro("Livro de Machado", { autores: ["Machado de Assis"] }),
      livro("Livro de Rosa", { autores: ["Guimaraes Rosa"] }),
    ]);
    await page.fill("#filtro-autor", "machado");
    await page.click("button:has-text('Pesquisar')");
    expect(await titulosNaTela(page)).toEqual(["Livro de Machado"]);
  });

  test("Limpar filtros traz todos de volta", async ({ page }) => {
    await abrir(page, [livro("Primeiro"), livro("Segundo")]);
    await page.fill("#filtro-titulo", "primeiro");
    await page.click("button:has-text('Pesquisar')");
    expect(await titulosNaTela(page)).toHaveLength(1);
    await page.click("button:has-text('Limpar filtros')");
    expect(await titulosNaTela(page)).toHaveLength(2);
  });
});
