const { test, expect } = require("@playwright/test");
const { livro, abrir, responderDialogos } = require("../ajuda");

/**
 * A varredura que teria pegado o Remover.
 *
 * Em 12/10/2026 o usuario relatou que o botao Remover "parou de funcionar". Ele
 * nunca funcionara no Mac — mas o que doi aqui e outra coisa: NADA no projeto
 * teria avisado se um botao qualquer deixasse de responder. A cobranca dele foi
 * essa, e com razao: "se nos nao mexemos nessa funcionalidade, como ela parou
 * de funcionar?".
 *
 * Duas redes, nesta ordem:
 *
 *   1. acionar todo botao seguro e exigir que NENHUM derrube o programa;
 *   2. para os botoes que fazem o trabalho do dia a dia, exigir um efeito
 *      ESPECIFICO e observavel — nao basta nao quebrar, tem de fazer.
 *
 * Ficam de fora os que abrem dialogo do sistema (escolher pasta, escolher foto),
 * os que baixam arquivo, os que imprimem, e os dois destrutivos — Apagar tudo e
 * Encerrar. Nao por serem menos importantes: por precisarem de outro tipo de
 * teste, e porque um deles apagaria a base do proprio teste.
 */
const FORA_DA_VARREDURA = [
  "btn-limpar-tudo",              // apagaria a base do teste
  "btn-encerrar", "btn-encerrar-topo",
  "btn-vincular",                 // abre o seletor de pasta do sistema
  "btn-importar", "btn-importar-excel",
  "btn-exportar", "btn-exportar-excel-resultado", "btn-exportar-fotos-dat",
  "btn-backup-json", "btn-backup",
  "btn-imprimir-resultados",
  "btn-buscar-isbn",              // depende da rede; testado a parte
  "btn-restaurar-json",           // depende de texto colado na caixa
];
const TEXTO_FORA = ["Selecionar foto", "Imprimir"];

test("nenhum botao da pagina derruba o programa", async ({ page }) => {
  responderDialogos(page, false);           // recusa tudo: a varredura nao pode apagar nada
  const erros = await abrir(page, [livro("Um Livro"), livro("Outro Livro")]);

  const alvos = await page.$$("button");
  let acionados = 0;
  for (const b of alvos) {
    if (!(await b.isVisible())) continue;
    const id = (await b.getAttribute("id")) || "";
    const txt = ((await b.textContent()) || "").trim();
    if (FORA_DA_VARREDURA.includes(id)) continue;
    if (TEXTO_FORA.some((t) => txt.startsWith(t))) continue;
    await b.click({ timeout: 3000 }).catch(() => {});
    acionados++;
    await page.waitForTimeout(40);
  }

  // Recusar o zero: varredura que nao acionou nada nao prova coisa alguma.
  expect(acionados).toBeGreaterThan(8);
  expect(erros).toEqual([]);
});

test("cada botao do dia a dia FAZ alguma coisa", async ({ page }) => {
  responderDialogos(page, true);
  await abrir(page, [livro("Alfa"), livro("Beta")]);

  // + Adicionar autor cria um campo que nao existia
  expect(await page.locator("#autores-container .autor-input").count()).toBe(0);
  await page.click("button.btn-add-autor[data-target='autores-container']");
  expect(await page.locator("#autores-container .autor-input").count()).toBe(1);

  // + Adicionar tema, idem
  await page.click("button.btn-add-tema[data-target='temas-container']");
  expect(await page.locator("#temas-container .tema-input").count()).toBe(1);

  // Limpar esvazia o formulario de cadastro
  await page.fill("#titulo", "Rascunho");
  await page.click("#btn-limpar-cadastro");
  expect(await page.inputValue("#titulo")).toBe("");

  // Pesquisar reduz a lista; Limpar filtros devolve
  await page.fill("#filtro-titulo", "alfa");
  await page.click("#btn-pesquisar");
  expect(await page.locator("table tbody tr").count()).toBe(1);
  await page.click("#btn-limpar-filtros");
  expect(await page.locator("table tbody tr").count()).toBe(2);

  // Editar abre a janela de edicao com o livro certo
  await page.click("tr:has-text('Alfa') button[data-action='editar']");
  await expect(page.locator("#modal-edicao, #form-edicao")).toBeVisible();
  expect(await page.inputValue("#edit-titulo")).toBe("Alfa");
});

test("Buscar ISBN recusa numero invalido e DIZ isso", async ({ page }) => {
  await abrir(page, []);
  await page.fill("#isbn-input", "123");
  await page.click("#btn-buscar-isbn");
  await expect(page.locator("#isbn-status")).toContainText(/inv[aá]lido/i);
});
