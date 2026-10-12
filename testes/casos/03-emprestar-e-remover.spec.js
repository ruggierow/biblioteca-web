const { test, expect } = require("@playwright/test");
const { livro, abrir, titulosNaTela, livrosGravados, responderDialogos } = require("../ajuda");

test.describe("Acoes da linha", () => {
  test("Emprestar marca o livro, Devolver desmarca", async ({ page }) => {
    await abrir(page, [livro("Para Emprestar")]);
    await page.click("button[data-action='emprestar']");
    expect((await livrosGravados(page))[0].emprestado).toBe(true);
    await page.click("button[data-action='devolver']");
    expect((await livrosGravados(page))[0].emprestado).toBe(false);
  });

  // ESTE e o teste do defeito de 12/10/2026. Ele NAO pega a causa (a falta do
  // WKUIDelegate no Mac) — aqui o confirm existe. Pega a outra metade: que a
  // logica de remover realmente remove quando a resposta e sim.
  test("Remover apaga o livro quando se confirma", async ({ page }) => {
    responderDialogos(page, true);
    await abrir(page, [livro("Vai Sair"), livro("Fica")]);
    await page.click("tr:has-text('Vai Sair') button[data-action='remover']");
    expect(await titulosNaTela(page)).toEqual(["Fica"]);
    expect((await livrosGravados(page)).map((l) => l.titulo)).toEqual(["Fica"]);
  });

  test("Remover NAO apaga quando se cancela", async ({ page }) => {
    responderDialogos(page, false);
    await abrir(page, [livro("Nao Sai")]);
    await page.click("button[data-action='remover']");
    expect(await titulosNaTela(page)).toEqual(["Nao Sai"]);
  });
});
