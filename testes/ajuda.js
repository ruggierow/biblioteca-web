// Peças comuns aos testes. O objetivo é que cada caso leia como uma frase.
const { expect } = require("@playwright/test");

/** Um livro no formato que a página guarda no localStorage. */
function livro(titulo, extras = {}) {
  return {
    titulo,
    autores: ["Autor de Teste"],
    temas: ["Teste"],
    ano: 2020,
    emprestado: false,
    comentarios: "",
    local: "Estante de teste",
    grupoLiteratura: [],
    ...extras,
  };
}

/**
 * Abre a página com uma base conhecida.
 *
 * A semente entra ANTES de qualquer script rodar (`addInitScript`): se entrasse
 * depois, a página já teria lido o localStorage vazio e desenhado uma lista sem
 * livros — o teste passaria a medir a semente, não o programa.
 */
async function abrir(page, livros = []) {
  const erros = [];
  page.on("pageerror", (e) => erros.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") erros.push(m.text());
  });
  await page.addInitScript((dados) => {
    localStorage.setItem("biblioteca-livros", JSON.stringify(dados));
    localStorage.setItem("biblioteca-fotos", "{}");
  }, livros);
  await page.goto("/biblioteca.html");
  await expect(page.locator("#carregando")).toBeHidden();
  return erros;
}

/** Os títulos que a tabela está mostrando, na ordem em que aparecem. */
async function titulosNaTela(page) {
  return page.$$eval("table tbody tr td:nth-child(2)", (tds) =>
    tds.map((td) => td.textContent.trim()),
  );
}

/** Responde aos `confirm()` da página — no navegador eles existem de verdade. */
function responderDialogos(page, resposta = true) {
  page.on("dialog", (d) => (resposta ? d.accept() : d.dismiss()));
}

/** Os livros como a página os gravou — a fonte da verdade, não a tela. */
async function livrosGravados(page) {
  return page.evaluate(() =>
    JSON.parse(localStorage.getItem("biblioteca-livros") || "[]"),
  );
}

/**
 * Preenche e envia o formulário de cadastro.
 *
 * Autor e tema NÃO existem até alguém clicar em "+ Adicionar" — e o cadastro
 * exige pelo menos um de cada. A primeira versão destes testes não sabia disso
 * e falhou; o erro era meu, não do programa, mas é o tipo de coisa que só
 * aparece quando se exercita a tela de verdade.
 */
async function cadastrar(page, { titulo, autor = "Autor de Teste", tema = "Teste", ano = "2024", local = "", pais = null }) {
  await page.fill("#titulo", titulo);
  await page.fill("#ano", String(ano));
  if (local) await page.fill("#local", local);
  if (pais !== null) await page.selectOption("#pais", pais);
  await page.click("button.btn-add-autor[data-target='autores-container']");
  await page.fill("#autores-container .autor-input >> nth=0", autor);
  await page.click("button.btn-add-tema[data-target='temas-container']");
  await page.fill("#temas-container .tema-input >> nth=0", tema);
  await page.click("#form-cadastro button:has-text('Cadastrar')");
}

module.exports = { livro, abrir, titulosNaTela, responderDialogos, livrosGravados, cadastrar };
