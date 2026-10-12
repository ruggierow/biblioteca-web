const { test, expect } = require("@playwright/test");
const { livro, abrir, livrosGravados } = require("../ajuda");

/**
 * A nona coluna (pais) entra em DUAS etapas, e esta versao e a primeira: a
 * pagina aprende a ler e a DEVOLVER o campo, sem ainda mostrar nada.
 *
 * Por que a ordem importa: ate a 1.9.13 o leitor fazia
 *
 *     if (campos.length < 5 || campos.length > 8) continue;
 *
 * e uma linha de 9 campos era descartada EM SILENCIO. Como o Mac salva sozinho,
 * bastaria um arquivo com a coluna nova para a biblioteca abrir vazia e o vazio
 * ser gravado por cima. Estes testes guardam exatamente isso.
 */
test.describe("Nona coluna: pais", () => {
  test("linha de 9 campos NAO e descartada", async ({ page }) => {
    await abrir(page, []);
    const lidos = await page.evaluate(() =>
      parseTSV("Livro com Pais\tAutor\tTema\t2020\t0\t\tEstante\t0\tBR"),
    );
    expect(lidos).toHaveLength(1);
    expect(lidos[0].titulo).toBe("Livro com Pais");
    expect(lidos[0].pais).toBe("BR");
  });

  test("linha de 8 campos continua valendo, com pais vazio", async ({ page }) => {
    await abrir(page, []);
    const lidos = await page.evaluate(() =>
      parseTSV("Livro Antigo\tAutor\tTema\t2020\t0\t\tEstante\t0"),
    );
    expect(lidos).toHaveLength(1);
    expect(lidos[0].pais).toBe("");
  });

  test("linha de 10 campos SEGUE sendo descartada", async ({ page }) => {
    await abrir(page, []);
    const lidos = await page.evaluate(() =>
      parseTSV("Demais\tAutor\tTema\t2020\t0\t\tEstante\t0\tBR\tsobra"),
    );
    expect(lidos).toHaveLength(0);
  });

  test("ida e volta: o pais sobrevive a gravar e reler", async ({ page }) => {
    await abrir(page, []);
    const resultado = await page.evaluate(() => {
      biblioteca = parseTSV("Ida e Volta\tAutor\tTema\t2020\t0\tnota\tEstante\t0\tJP");
      const texto = serializarTSV();
      const devolta = parseTSV(texto);
      return { colunas: texto.trim().split("\t").length, pais: devolta[0].pais, texto: texto.trim() };
    });
    expect(resultado.colunas).toBe(9);
    expect(resultado.pais).toBe("JP");
    expect(resultado.texto).toBe("Ida e Volta\tAutor\tTema\t2020\t0\tnota\tEstante\t0\tJP");
  });

  // Livro sem pais sai com OITO colunas, como sempre saiu. Escrever a nona
  // vazia poria um tabulador no fim de toda linha e faria o arquivo inteiro
  // aparecer como alterado a cada gravacao.
  test("livro SEM pais continua com 8 colunas", async ({ page }) => {
    await abrir(page, [livro("Sem Pais")]);
    const texto = await page.evaluate(() => serializarTSV());
    expect(texto.trim().split("\t")).toHaveLength(8);
    const devolta = await page.evaluate((t) => parseTSV(t), texto);
    expect(devolta).toHaveLength(1);
    expect(devolta[0].pais).toBe("");
  });

  test("base MISTA de 8 e 9 colunas: nenhum livro se perde", async ({ page }) => {
    await abrir(page, []);
    const r = await page.evaluate(() => {
      const texto = [
        "Com Pais\tAutor\tTema\t2020\t0\t\tEstante\t0\tBR",
        "Sem Pais\tAutor\tTema\t2021\t0\t\tEstante\t0",
      ].join("\n");
      biblioteca = parseTSV(texto);
      const devolta = parseTSV(serializarTSV());
      return devolta.map((l) => [l.titulo, l.pais]);
    });
    expect(r).toEqual([["Com Pais", "BR"], ["Sem Pais", ""]]);
  });

  // O teste que mais importa nesta etapa. Preservar na leitura e na gravacao
  // nao basta: se a EDICAO reconstruir o livro, o pais some em silencio no
  // primeiro conserto de titulo que o usuario fizer. Hoje a pagina altera o
  // objeto existente campo a campo, e e isso que este caso tranca.
  test("EDITAR um livro preserva o pais", async ({ page }) => {
    await abrir(page, []);
    await page.evaluate(() => {
      biblioteca = parseTSV("Antigo\tAutor\tTema\t2020\t0\t\tEstante\t0\tBR");
      atualizarTudo();
    });
    await page.click("button[data-action='editar']");
    await page.fill("#edit-titulo", "Titulo Corrigido");
    await page.click("#form-edicao button:has-text('Salvar')");
    const texto = await page.evaluate(() => serializarTSV());
    expect(texto.trim()).toContain("Titulo Corrigido");
    expect(texto.trim().split("\t")[8]).toBe("BR");
  });

  test("EMPRESTAR preserva o pais", async ({ page }) => {
    await abrir(page, []);
    await page.evaluate(() => {
      biblioteca = parseTSV("Livro\tAutor\tTema\t2020\t0\t\tEstante\t0\tFR");
      atualizarTudo();
    });
    await page.click("button[data-action='emprestar']");
    const campos = await page.evaluate(() => serializarTSV().trim().split("\t"));
    expect(campos[4]).toBe("1");
    expect(campos[8]).toBe("FR");
  });

  test("o codigo e guardado em MAIUSCULAS", async ({ page }) => {
    await abrir(page, []);
    const lidos = await page.evaluate(() =>
      parseTSV("Minusculo\tAutor\tTema\t2020\t0\t\tEstante\t0\tbr"),
    );
    expect(lidos[0].pais).toBe("BR");
  });
});
