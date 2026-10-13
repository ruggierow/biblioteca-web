const { test, expect } = require("@playwright/test");
const { abrir, cadastrar } = require("../ajuda");

/**
 * O CAMPO de pais nos formularios — a terceira e ultima etapa da nona coluna.
 *
 * As duas primeiras ensinaram a pagina a LER (caso 05) e a DESENHAR (caso 06) o
 * pais. Nenhuma das duas dava como ESCREVE-LO: ate aqui os 280 paises da base
 * vinham todos de `bin/semear-pais.py`, de fora do app, e o semeador se esgotou
 * (os 470 restantes nao tem gentilico no tema nem ISBN gravado — medido em
 * 13/10/2026). Sem campo no formulario nao havia como por pais num livro nem,
 * pior, como CORRIGIR um pais errado.
 *
 * O que estes casos trancam, em ordem de importancia:
 *
 *   1. escolher um pais grava a nona coluna;
 *   2. o seletor ABRE no pais do livro — senao salvar sem olhar troca o pais;
 *   3. da para voltar a "sem pais" (desfazer);
 *   4. um codigo fora da tabela NAO desaparece do seletor (seria apagar dado
 *      do usuario em silencio, a familia de defeito que mais nos custou);
 *   5. o seletor nao vaza de um cadastro para o proximo.
 */
test.describe("Campo de pais no formulario", () => {
  test("o seletor sai da tabela PAISES, com o vazio na frente", async ({ page }) => {
    await abrir(page, []);
    const opcoes = await page.$$eval("#pais option", (os) =>
      os.map((o) => ({ valor: o.value, texto: o.textContent, desligada: o.disabled })),
    );
    // A primeira opcao e o vazio: livro sem pais e o estado normal.
    expect(opcoes[0].valor).toBe("");
    // 47 paises de verdade, mais os cabecalhos de continente (desligados).
    const paises = opcoes.filter((o) => o.valor && !o.desligada);
    expect(paises).toHaveLength(47);
    const tabela = await page.evaluate(() => Object.keys(PAISES).length);
    expect(paises).toHaveLength(tabela);
    expect(opcoes.some((o) => o.desligada && o.texto.includes("EUROPA"))).toBe(true);
  });

  // Dentro do continente, ordem pelo NOME mostrado e IGNORANDO acento. Numa
  // comparacao por codigo de caractere toda inicial acentuada vai para o fim
  // do grupo: "Austria" cairia depois de Tchequia, longe da letra A. Era isso
  // que acontecia no Android em 13/10/2026, que nao tem colacao local; aqui o
  // localeCompare("pt") resolve, e este caso tranca.
  test("cada continente vem ordenado pelo nome, com acento no lugar da letra", async ({ page }) => {
    await abrir(page, []);
    const opcoes = await page.$$eval("#pais option", (os) =>
      os.filter((o) => o.value || o.disabled)
        .map((o) => ({ cabecalho: o.disabled, texto: o.textContent })),
    );
    const grupos = {};
    let atual = null;
    for (const o of opcoes) {
      if (o.cabecalho) { atual = o.texto.replace(/[^A-Z ]/g, "").trim(); grupos[atual] = []; }
      else if (atual) grupos[atual].push(o.texto);
    }
    expect(Object.keys(grupos)).toEqual([
      "AMERICA DO SUL", "AMERICA DO NORTE", "EUROPA", "ASIA", "AFRICA", "OCEANIA",
    ]);
    const semAcento = (t) => t.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
    for (const [continente, nomes] of Object.entries(grupos)) {
      const esperado = [...nomes].sort((a, b) => semAcento(a).localeCompare(semAcento(b)));
      expect(nomes, `ordem de ${continente}`).toEqual(esperado);
    }
    // As duas que o acento deslocaria, cada uma no seu grupo.
    expect(grupos["EUROPA"].indexOf("\u00c1ustria")).toBe(grupos["EUROPA"].indexOf("Alemanha") + 1);
    expect(grupos["AFRICA"][0]).toBe("\u00c1frica do Sul");
  });

  // A grafia e a MESMA dos dois celulares. Antes de 13/10/2026 a tabela do
  // motor-web estava sem acento em 22 dos 47 nomes: o mesmo livro aparecia em
  // "Mocambique" no Mac e em "Moçambique" no iPhone.
  test("os nomes vem acentuados", async ({ page }) => {
    await abrir(page, []);
    const nomes = await page.$$eval("#pais option", (os) => os.map((o) => o.textContent));
    for (const esperado of ["Mo\u00e7ambique", "\u00c1frica do Sul", "Fran\u00e7a", "Jap\u00e3o", "R\u00fassia"]) {
      expect(nomes).toContain(esperado);
    }
  });

  test("CADASTRAR com pais grava a nona coluna", async ({ page }) => {
    await abrir(page, []);
    await page.selectOption("#pais", "JP");
    await cadastrar(page, { titulo: "Livro Japones" });
    const campos = await page.evaluate(() => serializarTSV().trim().split("\t"));
    expect(campos[0]).toBe("Livro Japones");
    expect(campos[8]).toBe("JP");
  });

  test("CADASTRAR sem escolher pais segue gravando 8 colunas", async ({ page }) => {
    await abrir(page, []);
    await cadastrar(page, { titulo: "Livro Sem Pais" });
    const campos = await page.evaluate(() => serializarTSV().trim().split("\t"));
    expect(campos).toHaveLength(8);
  });

  test("o seletor volta ao vazio depois de cadastrar", async ({ page }) => {
    await abrir(page, []);
    await page.selectOption("#pais", "FR");
    await cadastrar(page, { titulo: "Primeiro" });
    // Se o pais vazasse, o livro seguinte nasceria frances sem ninguem pedir.
    expect(await page.inputValue("#pais")).toBe("");
  });

  test("EDITAR abre o seletor JA no pais do livro", async ({ page }) => {
    await abrir(page, []);
    await page.evaluate(() => {
      biblioteca = parseTSV("Antigo\tAutor\tTema\t2020\t0\t\tEstante\t0\tRU");
      atualizarTudo();
    });
    await page.click("button[data-action='editar']");
    expect(await page.inputValue("#edit-pais")).toBe("RU");
  });

  test("EDITAR grava o pais escolhido", async ({ page }) => {
    await abrir(page, []);
    await page.evaluate(() => {
      biblioteca = parseTSV("Sem Pais\tAutor\tTema\t2020\t0\t\tEstante\t0");
      atualizarTudo();
    });
    await page.click("button[data-action='editar']");
    expect(await page.inputValue("#edit-pais")).toBe("");
    await page.selectOption("#edit-pais", "PT");
    await page.click("#form-edicao button:has-text('Salvar')");
    const campos = await page.evaluate(() => serializarTSV().trim().split("\t"));
    expect(campos[8]).toBe("PT");
  });

  test("EDITAR consegue DESFAZER um pais posto por engano", async ({ page }) => {
    await abrir(page, []);
    await page.evaluate(() => {
      biblioteca = parseTSV("Errado\tAutor\tTema\t2020\t0\t\tEstante\t0\tCN");
      atualizarTudo();
    });
    await page.click("button[data-action='editar']");
    await page.selectOption("#edit-pais", "");
    await page.click("#form-edicao button:has-text('Salvar')");
    const campos = await page.evaluate(() => serializarTSV().trim().split("\t"));
    expect(campos).toHaveLength(8);   // a nona coluna deixa de ser escrita
  });

  test("um codigo FORA da tabela nao desaparece ao editar", async ({ page }) => {
    await abrir(page, []);
    await page.evaluate(() => {
      biblioteca = parseTSV("Exotico\tAutor\tTema\t2020\t0\t\tEstante\t0\tNZ");
      atualizarTudo();
    });
    await page.click("button[data-action='editar']");
    // NZ nao esta em PAISES. Se o seletor o omitisse, abrir e salvar apagaria
    // o pais do livro sem dizer nada.
    expect(await page.evaluate(() => PAISES["NZ"])).toBeUndefined();
    expect(await page.inputValue("#edit-pais")).toBe("NZ");
    await page.click("#form-edicao button:has-text('Salvar')");
    const campos = await page.evaluate(() => serializarTSV().trim().split("\t"));
    expect(campos[8]).toBe("NZ");
  });
});
