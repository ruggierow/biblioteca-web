const { test, expect } = require("@playwright/test");
const { livro, abrir, titulosNaTela, livrosGravados, responderDialogos, cadastrar } = require("../ajuda");

test.describe("Cadastro", () => {
  test("cadastra um livro e ele aparece na lista e na base", async ({ page }) => {
    await abrir(page, []);
    await cadastrar(page, { titulo: "Livro Novo", local: "Prateleira 1" });
    expect(await titulosNaTela(page)).toContain("Livro Novo");
    const base = await livrosGravados(page);
    expect(base.map((l) => l.titulo)).toContain("Livro Novo");
    expect(base.find((l) => l.titulo === "Livro Novo").local).toBe("Prateleira 1");
  });

  test("exige pelo menos um autor e um tema", async ({ page }) => {
    await abrir(page, []);
    await page.fill("#titulo", "Sem Autor");
    await page.fill("#ano", "2024");
    await page.click("#form-cadastro button:has-text('Cadastrar')");
    expect((await livrosGravados(page)).map((l) => l.titulo)).not.toContain("Sem Autor");
  });

  test("RECUSA duplicata exata: mesmo titulo e mesmo autor", async ({ page }) => {
    responderDialogos(page, true);
    await abrir(page, [livro("Repetido", { autores: ["Fulano"], temas: ["Teste"] })]);
    await cadastrar(page, { titulo: "Repetido", autor: "Fulano" });
    const base = await livrosGravados(page);
    expect(base.filter((l) => l.titulo === "Repetido")).toHaveLength(1);
  });

  test("livro PARECIDO so entra se o usuario confirmar", async ({ page }) => {
    responderDialogos(page, false);   // o usuario diz "nao, deixa pra la"
    await abrir(page, [livro("Historia do Brasil Colonial", { autores: ["Fulano"] })]);
    await cadastrar(page, { titulo: "Historia do Brasil Colonia", autor: "Fulano" });
    const base = await livrosGravados(page);
    expect(base).toHaveLength(1);
  });
});
