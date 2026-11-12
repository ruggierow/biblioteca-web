const { test, expect } = require("@playwright/test");
const { livro, abrir } = require("../ajuda");

/**
 * A pagina fala portugues e ingles.
 *
 * O desenho tem tres pecas: um dicionario `TEXTOS` com as duas linguas, o
 * atributo `data-i18n` que liga um elemento a uma chave, e `t(chave, ...)`
 * para o que o codigo monta. O portugues continua escrito no HTML — chave que
 * falte deixa o portugues na tela, nunca a chave crua.
 *
 * DUAS COISAS QUE ESTES CASOS GUARDAM, e que nenhuma leitura do codigo pega:
 *
 * 1. **Meia traducao.** Uma chave nova so em `pt` passaria despercebida: a
 *    tela fica certa em portugues e so quebra para quem le em ingles. O
 *    primeiro caso compara os dois conjuntos de chaves.
 *
 * 2. **O idioma do aparelho manda na primeira abertura.** O resto da suite
 *    roda com `locale: "pt-BR"` fixado no playwright.config.js justamente
 *    porque o padrao do Playwright e `en-US` — sem isso os 73 casos escritos
 *    em portugues quebrariam todos. Aqui e o contrario: este arquivo PEDE
 *    `en-US` para si, e por isso mede o que os outros nao podem medir.
 */
test.describe("Idioma", () => {
  test("toda chave do portugues existe no ingles, e vice-versa", async ({ page }) => {
    await abrir(page, []);
    const { soEmPt, soEmEn, total } = await page.evaluate(() => {
      const pt = Object.keys(TEXTOS.pt), en = Object.keys(TEXTOS.en);
      return {
        soEmPt: pt.filter((k) => !(k in TEXTOS.en)),
        soEmEn: en.filter((k) => !(k in TEXTOS.pt)),
        total: pt.length,
      };
    });
    expect(soEmPt).toEqual([]);
    expect(soEmEn).toEqual([]);
    expect(total).toBeGreaterThan(200);
  });

  test("nenhuma chave ficou com o texto portugues copiado no ingles", async ({ page }) => {
    await abrir(page, []);
    // As cinco excecoes sao deliberadas:
    //   backup, status, colStatus  "Status" e "Backup" sao a mesma palavra
    //   idiomaDica                 a dica do seletor e bilingue de proposito
    //   linhaSimilar               so pontuacao e "similar", igual nas duas
    // Qualquer OUTRA chave identica e traducao esquecida, e reprova aqui.
    const iguais = await page.evaluate(() =>
      Object.keys(TEXTOS.pt).filter((k) => TEXTOS.pt[k] === TEXTOS.en[k]),
    );
    expect(iguais.sort()).toEqual(
      ["backup", "colStatus", "idiomaDica", "linhaSimilar", "status"]);
  });

  test.describe("num aparelho em ingles", () => {
    test.use({ locale: "en-US" });

    test("a pagina abre em ingles sozinha", async ({ page }) => {
      await abrir(page, [livro("Qualquer Livro")]);
      await expect(page.locator("#btn-pesquisar")).toHaveText("Search");
      await expect(page.locator("h2").first()).toHaveText("Add a book");
      await expect(page.locator("#seletor-idioma")).toHaveValue("en");
      expect(await page.getAttribute("html", "lang")).toBe("en");
    });

    test("o que o CODIGO monta tambem sai em ingles", async ({ page }) => {
      await abrir(page, [livro("Qualquer Livro")]);
      // Cabecalho da tabela, pilula de status e botoes de acao nao estao no
      // HTML: `renderizar()` os monta a cada desenho.
      const colunas = await page.$$eval("table thead th", (th) =>
        th.map((e) => e.textContent.trim()),
      );
      expect(colunas).toEqual(["Photo", "Title", "Author", "Subject", "Year",
                               "Status", "Location", "Notes", "Group", "Actions"]);
      await expect(page.locator(".status-pill").first()).toHaveText("Available");
      await expect(page.locator("[data-action='emprestar']").first()).toHaveText("Lend");
    });

    test("o seletor de pais sai em ingles, com os continentes", async ({ page }) => {
      await abrir(page, []);
      const textos = await page.$$eval("#pais option", (o) =>
        o.map((e) => e.textContent.trim()),
      );
      expect(textos).toContain("Brazil");
      expect(textos).toContain("United States");
      expect(textos.some((x) => x.includes("SOUTH AMERICA"))).toBe(true);
      expect(textos).not.toContain("Brasil");
    });

    test("o portugues continua a dois cliques", async ({ page }) => {
      await abrir(page, []);
      await page.selectOption("#seletor-idioma", "pt");
      await expect(page.locator("#btn-pesquisar")).toHaveText("Pesquisar");
      expect(await page.getAttribute("html", "lang")).toBe("pt-BR");
      // E a escolha sobrevive a recarregar, mesmo com o aparelho em ingles.
      await page.reload();
      await expect(page.locator("#carregando")).toBeHidden();
      await expect(page.locator("#btn-pesquisar")).toHaveText("Pesquisar");
    });
  });

  test("num aparelho em portugues a pagina abre em portugues", async ({ page }) => {
    await abrir(page, []);
    await expect(page.locator("#btn-pesquisar")).toHaveText("Pesquisar");
    await expect(page.locator("#seletor-idioma")).toHaveValue("pt");
    expect(await page.getAttribute("html", "lang")).toBe("pt-BR");
  });

  test("trocar para ingles redesenha a lista ja na tela", async ({ page }) => {
    await abrir(page, [livro("Qualquer Livro")]);
    await expect(page.locator(".status-pill").first()).toHaveText("Disponível");
    await page.selectOption("#seletor-idioma", "en");
    // Nao basta trocar o que esta escrito no HTML: a tabela e montada por
    // codigo e precisa ser redesenhada.
    await expect(page.locator(".status-pill").first()).toHaveText("Available");
    await expect(page.locator("#contador")).toHaveText("1 of 1 book(s)");
  });

  test("chave que nao existe deixa o portugues do HTML na tela", async ({ page }) => {
    await abrir(page, []);
    // Apaga uma chave do dicionario ingles e manda traduzir de novo: o
    // elemento tem de ficar como estava, nunca virar "pesquisar".
    const texto = await page.evaluate(() => {
      delete TEXTOS.en.pesquisar;
      IDIOMA = "en";
      traduzirPagina();
      return document.getElementById("btn-pesquisar").textContent;
    });
    expect(texto).toBe("Pesquisar");
  });

  /**
   * A FICHA IMPRESSA E A PLANILHA — a 2a etapa.
   *
   * Nenhuma das duas aparece na tela: `imprimirDocumento` abre outra janela e
   * a planilha sai como arquivo. Aqui a janela e trocada por uma funcao que
   * guarda o HTML, e a planilha e lida como bytes — o ZIP que a pagina monta
   * guarda os XML SEM compressao, entao o texto esta a vista.
   */
  test.describe("impressao e planilha", () => {
    const comLivro = [livro("Pride and Prejudice", { local: "Shelf 3" })];

    async function fichaDe(page) {
      return page.evaluate(() => {
        let capturado = "";
        const original = window.imprimirDocumento;
        window.imprimirDocumento = (html) => { capturado = html; };
        imprimirLivro(biblioteca[0]);
        window.imprimirDocumento = original;
        return capturado;
      });
    }

    async function relatorioDe(page) {
      return page.evaluate(() => {
        let capturado = "";
        const original = window.imprimirDocumento;
        window.imprimirDocumento = (html) => { capturado = html; };
        imprimirResultados();
        window.imprimirDocumento = original;
        return capturado;
      });
    }

    /** O texto cru do .xlsx: o ZIP guarda os XML sem comprimir. */
    async function planilhaDe(page) {
      return page.evaluate(() => {
        const bytes = gerarXLSX(aplicarFiltros());
        return new TextDecoder("latin1").decode(bytes);
      });
    }

    /**
     * O texto como ele aparece DENTRO do .xlsx.
     *
     * A planilha e um zip, e por isso a lemos byte a byte (latin1) — ler como
     * UTF-8 estragaria a estrutura. O efeito colateral e que "Comentários"
     * aparece ali como os bytes UTF-8 vistos um a um. Converter aqui mantem a
     * afirmacao escrita em portugues de verdade, em vez de afrouxa-la para um
     * pedaco sem acento.
     */
    const comoNoZip = (s) =>
      new TextDecoder("latin1").decode(new TextEncoder().encode(s));

    test("em portugues, as tres saem em portugues", async ({ page }) => {
      await abrir(page, comLivro);
      const ficha = await fichaDe(page);
      expect(ficha).toContain("Cadastro do Livro");
      expect(ficha).toContain("<dt>Título</dt>");
      expect(ficha).toContain("Disponível");

      const relatorio = await relatorioDe(page);
      expect(relatorio).toContain("Relatório de Livros");
      expect(relatorio).toContain("Filtros aplicados:");
      expect(relatorio).toContain('lang="pt-BR"');

      const planilha = await planilhaDe(page);
      expect(planilha).toContain(comoNoZip("Comentários"));
      expect(planilha).toContain('name="Resultados"');
    });

    test.describe("num aparelho em ingles", () => {
      test.use({ locale: "en-US" });

      test("a ficha de um livro sai em ingles", async ({ page }) => {
        await abrir(page, comLivro);
        const ficha = await fichaDe(page);
        expect(ficha).toContain("Book record");
        expect(ficha).toContain("<dt>Title</dt>");
        expect(ficha).toContain("<dt>Status</dt><dd>Available</dd>");
        expect(ficha).toContain('lang="en"');
        expect(ficha).not.toContain("Cadastro do Livro");
      });

      test("o relatorio da pesquisa sai em ingles", async ({ page }) => {
        await abrir(page, comLivro);
        const relatorio = await relatorioDe(page);
        expect(relatorio).toContain("Book report");
        expect(relatorio).toContain("Filters applied:");
        expect(relatorio).toContain("Generated on:");
        expect(relatorio).toContain("Books in total:");
        expect(relatorio).toContain("record(s)");
        expect(relatorio).toContain('lang="en"');
        expect(relatorio).not.toContain("Relatório de Livros");
      });

      test("a planilha sai em ingles, cabecalho e aba", async ({ page }) => {
        await abrir(page, comLivro);
        const planilha = await planilhaDe(page);
        for (const coluna of ["Title", "Author(s)", "Subject(s)", "Year",
                              "Status", "Location", "Reading group", "Notes"]) {
          expect(planilha).toContain(coluna);
        }
        expect(planilha).toContain('name="Results"');
        expect(planilha).not.toContain("Grupo Literatura");
      });

      test("o filtro escrito no cabecalho do relatorio tambem e traduzido", async ({ page }) => {
        await abrir(page, comLivro);
        await page.fill("#filtro-titulo", "pride");
        await page.selectOption("#filtro-status", "disponivel");
        const relatorio = await relatorioDe(page);
        expect(relatorio).toContain('Title: "pride"');
        expect(relatorio).toContain("Status: Available");
      });
    });
  });
});
