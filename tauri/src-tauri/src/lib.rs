use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

// ---------------------------------------------------------------------------
// Onde ficam os arquivos
//
// O usuario sincroniza pelo iCloud para Windows, que instala a pasta em
// %USERPROFILE%\iCloudDrive — NAO na pasta Documentos. O Explorer mostra
// "iCloud Drive" com espaco, mas isso e apenas o nome de exibicao; no disco
// a pasta e "iCloudDrive". Procuramos as duas formas por seguranca.
//
// Ordem de busca (a primeira que tiver o arquivo vence):
//   1. pasta configurada pelo usuario (definir_pasta)
//   2. %USERPROFILE%\iCloudDrive\Biblioteca
//   3. %USERPROFILE%\iCloud Drive\Biblioteca      (variante com espaco)
//   4. Documentos\Biblioteca                       (segue OneDrive)
//   5. Documentos
// ---------------------------------------------------------------------------

/// Arquivo onde guardamos a pasta escolhida manualmente pelo usuario.
fn arquivo_config() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("Biblioteca").join("pasta.txt"))
}

/// O texto da pasta configurada, limpo. `None` quando nao ha arquivo ou esta
/// vazio — mas Some(...) mesmo que a pasta NAO exista, para quem chama poder
/// avisar a diferenca entre "nada configurado" e "configurado e inalcancavel".
fn pasta_configurada_texto() -> Option<String> {
    let cfg = arquivo_config()?;
    let texto = fs::read_to_string(cfg).ok()?;
    // O BOM do UTF-8 (U+FEFF) NAO e espaco em branco, entao `trim()` nao o
    // remove — e o Bloco de Notas grava UTF-8 com BOM por padrao, assim como o
    // `Set-Content -Encoding UTF8` do PowerShell.
    //
    // Em 03/11/2026 um pasta.txt com BOM fez o caminho virar invalido,
    // `is_dir()` responder falso e o aplicativo cair na pasta velha do iCloud
    // — que estava parada havia um mes. Sem erro, sem aviso: o usuario via a
    // biblioteca de outubro e nao tinha como saber por que.
    let limpo = texto.trim().trim_start_matches('\u{feff}').trim();
    if limpo.is_empty() { None } else { Some(limpo.to_string()) }
}

/// Pasta configurada manualmente, se houver e se ainda existir.
fn pasta_configurada() -> Option<PathBuf> {
    let caminho = PathBuf::from(pasta_configurada_texto()?);
    if caminho.is_dir() { Some(caminho) } else { None }
}

/// Todas as pastas onde procurar, em ordem de preferencia.
fn pastas_candidatas() -> Vec<PathBuf> {
    let mut v = Vec::new();

    if let Some(p) = pasta_configurada() {
        v.push(p);
    }
    if let Some(home) = dirs::home_dir() {
        v.push(home.join("iCloudDrive").join("Biblioteca"));
        v.push(home.join("iCloud Drive").join("Biblioteca"));
    }
    if let Some(docs) = dirs::document_dir() {
        v.push(docs.join("Biblioteca"));
        v.push(docs);
    }
    if v.is_empty() {
        v.push(PathBuf::from("."));
    }
    v
}

/// Pasta a usar quando nenhum arquivo existe ainda (para criar o primeiro).
/// Prefere o iCloud se a pasta raiz dele existir na maquina.
fn pasta_para_criar() -> PathBuf {
    if let Some(p) = pasta_configurada() {
        return p;
    }
    if let Some(home) = dirs::home_dir() {
        for nome in ["iCloudDrive", "iCloud Drive"] {
            if home.join(nome).is_dir() {
                return home.join(nome).join("Biblioteca");
            }
        }
    }
    if let Some(docs) = dirs::document_dir() {
        return docs.join("Biblioteca");
    }
    PathBuf::from(".")
}

/// Primeiro caminho candidato que contenha o arquivo indicado.
fn localizar(nome_arquivo: &str) -> Option<PathBuf> {
    pastas_candidatas()
        .into_iter()
        .map(|p| p.join(nome_arquivo))
        .find(|p| p.exists())
}

fn caminho_base() -> PathBuf {
    localizar("biblioteca.txt").unwrap_or_else(|| pasta_para_criar().join("biblioteca.txt"))
}

/// O .dat mora ao lado do .txt. Se o .txt ainda nao existe, procura o .dat
/// sozinho pelas mesmas pastas antes de decidir onde criar.
fn caminho_dat() -> PathBuf {
    let junto_txt = caminho_base().with_extension("dat");
    if junto_txt.exists() {
        return junto_txt;
    }
    localizar("biblioteca.dat").unwrap_or(junto_txt)
}

// ---------------------------------------------------------------------------
// Leitura resistente a arquivo ainda nao baixado
//
// No iCloud para Windows um arquivo pode existir apenas como marcador; a
// primeira leitura dispara o download e pode falhar enquanto ele nao chega.
// Tentamos algumas vezes antes de desistir — o equivalente ao
// startDownloadingUbiquitousItem que o app do Mac usa.
// ---------------------------------------------------------------------------

fn ler_com_retentativa(caminho: &Path) -> Result<String, String> {
    let mut ultimo_erro = String::new();
    for tentativa in 0..4 {
        match fs::read_to_string(caminho) {
            Ok(conteudo) => return Ok(conteudo),
            Err(e) => {
                ultimo_erro = e.to_string();
                // Se o arquivo nem existe, nao adianta insistir.
                if !caminho.exists() {
                    return Err(ultimo_erro);
                }
                thread::sleep(Duration::from_millis(400 * (tentativa + 1)));
            }
        }
    }
    Err(ultimo_erro)
}

// ---------------------------------------------------------------------------
// Guarda do .dat
//
// So gravamos as fotos depois de ter conseguido LER o .dat nesta sessao. Sem
// isso, uma falha de leitura (arquivo ainda na nuvem, por exemplo) faria a
// primeira gravacao sobrescrever o arquivo com o localStorage incompleto,
// apagando fotos que so existiam nele. E a mesma protecao que o modo
// navegador ganhou em 09/09 com _datLidoNestaSessao.
// ---------------------------------------------------------------------------

static DAT_LIDO: AtomicBool = AtomicBool::new(false);

// ---------------------------------------------------------------------------
// Backup automatico
//
// Copia o arquivo ANTES da primeira gravacao da sessao, preservando o ultimo
// estado bom. Fazer no fim da sessao seria tarde: se o app travar ou faltar
// energia nao ha encerramento, e um backup do que se esta deixando ja e o que
// esta no arquivo.
//
// So copia se o conteudo MUDOU em relacao ao backup mais recente. Isso importa
// porque o app do Mac reescreve o .dat toda vez que abre — por data de
// modificacao, geraria 9 MB de backup a cada abertura sem nada ter mudado.
//
// Rotacao: 30 geracoes do .txt (pequeno) e 7 do .dat (~9 MB cada).
// ---------------------------------------------------------------------------

const MAX_BACKUP_TXT: usize = 30;
const MAX_BACKUP_DAT: usize = 7;

static BACKUP_TXT_FEITO: AtomicBool = AtomicBool::new(false);
static BACKUP_DAT_FEITO: AtomicBool = AtomicBool::new(false);

/// Carimbo de data/hora do inicio da sessao, enviado pelo frontend (que tem a
/// hora local de graca). O backup representa o estado em que a sessao comecou,
/// entao nomea-lo com a hora de inicio e o mais fiel.
static SUFIXO_SESSAO: Mutex<String> = Mutex::new(String::new());

/// Informa o carimbo da sessao. Chamado uma vez, na abertura.
#[tauri::command]
fn iniciar_sessao(sufixo: String) {
    if let Ok(mut s) = SUFIXO_SESSAO.lock() {
        *s = sufixo;
    }
}

fn sufixo_atual() -> String {
    if let Ok(s) = SUFIXO_SESSAO.lock() {
        if !s.is_empty() {
            return s.clone();
        }
    }
    // Retaguarda, caso o frontend nao tenha avisado: segundos desde 1970.
    // Feio, mas nunca deve acontecer e e melhor que nao fazer backup.
    let seg = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("sessao-{}", seg)
}

fn pasta_backups(arquivo: &Path) -> PathBuf {
    arquivo
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("Backups")
}

/// Apaga os backups mais antigos, mantendo os `maximo` mais recentes.
/// Os nomes carregam a data no formato AAAA-MM-DD_HHhMM, que ordena igual
/// cronologicamente — entao ordenar por nome basta.
fn rotacionar(pasta: &Path, prefixo: &str, extensao: &str, maximo: usize) {
    let Ok(itens) = fs::read_dir(pasta) else { return };
    let mut nomes: Vec<PathBuf> = itens
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            let nome = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            nome.starts_with(prefixo) && nome.ends_with(extensao)
        })
        .collect();
    if nomes.len() <= maximo {
        return;
    }
    nomes.sort();
    let sobrando = nomes.len() - maximo;
    for antigo in nomes.into_iter().take(sobrando) {
        let _ = fs::remove_file(antigo);
    }
}

/// Copia o arquivo para Backups/ se ainda nao houve backup nesta sessao e se o
/// conteudo difere do backup mais recente.
fn backup_automatico(arquivo: &Path, maximo: usize, feito: &AtomicBool) {
    // Marca antes de tentar: se falhar, nao insiste a cada tecla digitada.
    if feito.swap(true, Ordering::SeqCst) {
        return;
    }
    if !arquivo.exists() {
        return; // nada a preservar ainda
    }
    let Ok(atual) = fs::read(arquivo) else { return };

    let pasta = pasta_backups(arquivo);
    let base = arquivo.file_stem().and_then(|s| s.to_str()).unwrap_or("biblioteca");
    let ext = arquivo.extension().and_then(|s| s.to_str()).unwrap_or("txt");
    let prefixo = format!("{}_", base);
    let sufixo_ext = format!(".{}", ext);

    // Se o backup mais recente ja tem exatamente este conteudo, nao duplica.
    if let Ok(itens) = fs::read_dir(&pasta) {
        let mut anteriores: Vec<PathBuf> = itens
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                let n = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
                n.starts_with(&prefixo) && n.ends_with(&sufixo_ext)
            })
            .collect();
        anteriores.sort();
        if let Some(ultimo) = anteriores.last() {
            if fs::read(ultimo).map(|b| b == atual).unwrap_or(false) {
                return; // nada mudou desde o ultimo backup
            }
        }
    }

    if fs::create_dir_all(&pasta).is_err() {
        return;
    }
    let destino = pasta.join(format!("{}{}{}", prefixo, sufixo_atual(), sufixo_ext));
    if fs::write(&destino, &atual).is_ok() {
        rotacionar(&pasta, &prefixo, &sufixo_ext, maximo);
    }
}


// ---------------------------------------------------------------------------
// Registro de exclusoes de fotos
//
// As capas viajam pelo biblioteca.dat e cada lado MESCLA o que tem com o que
// esta no arquivo — e mesclagem so sabe somar. Sem este registro, uma foto
// apagada aqui volta na proxima sincronizacao do iPhone, que ainda a tem.
//
// Formato (arquivo separado, para nao quebrar versoes antigas):
//   biblioteca-removidas.json  =  { "<fotoId>": "<ISO8601>" }
//
// Contrato completo em comum/exclusao-de-fotos.md
// ---------------------------------------------------------------------------

fn caminho_removidas() -> PathBuf {
    caminho_dat().with_file_name("biblioteca-removidas.json")
}

/// Le o registro. Mapa de fotoId -> carimbo.
fn ler_removidas() -> BTreeMap<String, String> {
    let caminho = caminho_removidas();
    if !caminho.exists() {
        return BTreeMap::new();
    }
    fs::read_to_string(&caminho)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// Devolve o registro ao frontend, para ele filtrar o que exibe.
#[tauri::command]
fn carregar_removidas() -> String {
    serde_json::to_string(&ler_removidas()).unwrap_or_else(|_| "{}".into())
}

/// Registra exclusoes. O frontend informa os ids EXPLICITAMENTE — nao deduzimos
/// por diferenca, porque uma memoria incompleta pareceria exclusao em massa.
#[tauri::command]
fn registrar_remocoes(ids: Vec<String>) -> Result<usize, String> {
    if ids.is_empty() {
        return Ok(0);
    }
    let mut reg = ler_removidas();
    let agora = carimbo_iso();
    for id in ids {
        reg.insert(id, agora.clone());
    }
    let caminho = caminho_removidas();
    if let Some(pai) = caminho.parent() {
        fs::create_dir_all(pai).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(&reg).map_err(|e| e.to_string())?;
    fs::write(&caminho, json).map_err(|e| e.to_string())?;
    Ok(reg.len())
}

/// Tira ids do registro: a capa foi reposta para aquele livro, entao ela pode
/// voltar a viajar entre os aparelhos. Sem isto, refotografar uma capa apagada
/// daria uma foto que some na proxima mescla.
#[tauri::command]
fn cancelar_remocoes(ids: Vec<String>) -> Result<usize, String> {
    if ids.is_empty() {
        return Ok(0);
    }
    let mut reg = ler_removidas();
    let antes = reg.len();
    for id in &ids {
        reg.remove(id);
    }
    if reg.len() == antes {
        return Ok(antes);
    }
    let caminho = caminho_removidas();
    if let Some(pai) = caminho.parent() {
        fs::create_dir_all(pai).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(&reg).map_err(|e| e.to_string())?;
    fs::write(&caminho, json).map_err(|e| e.to_string())?;
    Ok(reg.len())
}

/// Carimbo ISO8601 em UTC, sem dependencia nova: derivado do epoch.
fn carimbo_iso() -> String {
    let seg = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0) as i64;
    let dias = seg / 86_400;
    let resto = seg % 86_400;
    // Algoritmo civil-from-days (Howard Hinnant) — data a partir do dia do epoch.
    let z = dias + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y, m, d, resto / 3600, (resto % 3600) / 60, resto % 60
    )
}

// ---------------------------------------------------------------------------
// Comandos expostos ao frontend
// ---------------------------------------------------------------------------

/// Texto de diagnostico: onde os arquivos foram encontrados (ou nao).
///
/// Publico de proposito: o binario auxiliar `diagnostico` chama esta MESMA
/// funcao, para se conferir a resolucao de caminhos pela linha de comando sem
/// abrir a janela do app — e sem risco de a checagem divergir do que o app faz.
pub fn diagnostico_texto() -> String {
    let txt = caminho_base();
    let dat = caminho_dat();
    let origem = if pasta_configurada().is_some() { " (pasta configurada)" } else { "" };
    let pastas: Vec<String> = pastas_candidatas()
        .into_iter()
        .map(|p| {
            let marca = if p.join("biblioteca.txt").exists() { "  <== usa esta" } else { "" };
            format!("   - {}{}", p.display(), marca)
        })
        .collect();
    format!(
        "TXT: {} [{}]{}\nDAT: {} [{}]\nPastas procuradas, em ordem:\n{}",
        txt.display(),
        if txt.exists() { "encontrado" } else { "NÃO encontrado" },
        origem,
        dat.display(),
        if dat.exists() { "encontrado" } else { "NÃO encontrado" },
        pastas.join("\n")
    )
}

/// Diagnostico: onde os arquivos foram encontrados (ou nao) e qual pasta seria usada.
#[tauri::command]
fn diagnosticar() -> String {
    diagnostico_texto()
}

/// Lista as pastas procuradas, para o usuario entender de onde veio o arquivo.
#[tauri::command]
fn listar_pastas_procuradas() -> Vec<String> {
    pastas_candidatas()
        .into_iter()
        .map(|p| {
            let existe = if p.join("biblioteca.txt").exists() { " ← aqui" } else { "" };
            format!("{}{}", p.display(), existe)
        })
        .collect()
}

/// Grava no pasta.txt a pasta escolhida, SEM BOM.
///
/// Esta funcao e a razao de existir do botao "Selecionar pasta": ate a 1.9.20 a
/// unica forma de configurar a pasta era editar o pasta.txt a mao, e em
/// 03/11/2026 o Bloco de Notas o gravou com BOM. O BOM nao e espaco em branco,
/// o caminho virou invalido, `is_dir()` respondeu falso e o app caiu na pasta
/// velha do iCloud — servindo, calado, a biblioteca de um mes antes.
fn gravar_pasta_configurada(pasta: &Path) -> Result<(), String> {
    let cfg = arquivo_config().ok_or("Não foi possível determinar a pasta de configuração.")?;
    let pai = cfg.parent().ok_or("Caminho de configuração inválido.")?;
    fs::create_dir_all(pai).map_err(|e| e.to_string())?;
    fs::write(&cfg, pasta.to_string_lossy().as_bytes()).map_err(|e| e.to_string())?;
    // A pasta mudou: o .dat de la ainda nao foi lido nesta sessao.
    DAT_LIDO.store(false, Ordering::SeqCst);
    Ok(())
}

/// Define manualmente a pasta a usar. Passe "" para voltar ao automatico.
#[tauri::command]
fn definir_pasta(caminho: String) -> Result<String, String> {
    let limpo = caminho.trim().to_string();
    if limpo.is_empty() {
        let cfg = arquivo_config().ok_or("Não foi possível determinar a pasta de configuração.")?;
        let pai = cfg.parent().ok_or("Caminho de configuração inválido.")?;
        fs::create_dir_all(pai).map_err(|e| e.to_string())?;
        let _ = fs::remove_file(&cfg);
        return Ok("Voltou à detecção automática.".to_string());
    }
    if !PathBuf::from(&limpo).is_dir() {
        return Err(format!("A pasta não existe: {}", limpo));
    }
    gravar_pasta_configurada(Path::new(&limpo))?;
    Ok(limpo)
}

/// O roteiro de PowerShell do seletor de pastas.
///
/// Separado do comando para poder ser MEDIDO: o teste
/// `o_roteiro_do_seletor_atravessa_o_powershell` o roda de verdade, trocando
/// so a linha do `ShowDialog` (que esperaria por uma pessoa). O que ele mede e
/// a travessia: a aspa simples dobrada, o caminho com espaco e acento, e o
/// texto voltando pelo ARQUIVO em UTF-8 sem BOM.
///
/// NAO use aspas DUPLAS aqui. O roteiro inteiro viaja como UM argumento de
/// `-Command`, e aspa dupla dentro dele teria de sobreviver a tres camadas de
/// citacao (Rust, linha de comando do Windows, PowerShell). Com aspas simples
/// nao ha o que escapar — so a propria aspa simples, que se dobra.
fn script_do_seletor(inicial: &str, destino: &str) -> String {
    let citar = |s: &str| s.replace('\'', "''");
    format!(
        "Add-Type -AssemblyName System.Windows.Forms; \
         $d = New-Object System.Windows.Forms.FolderBrowserDialog; \
         $d.Description = 'Escolha a pasta onde fica o seu biblioteca.txt'; \
         $d.ShowNewFolderButton = $true; \
         $p = '{}'; \
         if ($p -ne '' -and (Test-Path -LiteralPath $p)) {{ $d.SelectedPath = $p }}; \
         if ($d.ShowDialog() -eq 'OK') {{ \
             [IO.File]::WriteAllText('{}', $d.SelectedPath, (New-Object Text.UTF8Encoding $false)) \
         }}",
        citar(inicial),
        citar(destino),
    )
}

/// Abre o seletor de pastas do Windows e devolve o caminho escolhido.
///
/// Devolve `Ok("")` quando o usuario fecha sem escolher: cancelar NAO e erro, e
/// trata-lo como erro faria a pagina mostrar um aviso a quem so mudou de ideia.
///
/// Comeca na pasta que o app esta usando (ou na que ele usaria para criar).
/// Assim o passo vira uma CONFIRMACAO em vez de uma procura, e o acerto
/// automatico do iCloud nao se perde.
///
/// POR QUE PowerShell e nao um plugin de dialogo: o `copiar_texto` deste mesmo
/// arquivo ja conversa com o Windows assim, e isto evita uma dependencia nova
/// — com a permissao de capacidade que vem junto, que, se faltasse, faria o
/// botao nao fazer NADA so no Windows, e em silencio.
///
/// O caminho volta por ARQUIVO, nao pela saida padrao: a saida do PowerShell
/// sai na pagina de codigo do console e um nome de pasta com acento voltaria
/// corrompido. `WriteAllText` com UTF-8 sem BOM volta exato.
#[tauri::command]
fn escolher_pasta() -> Result<String, String> {
    #[cfg(target_os = "windows")]
    {
        use std::process::Command;
        let inicial = caminho_base()
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        let tmp = std::env::temp_dir().join(format!("biblioteca-pasta-{}.txt", std::process::id()));
        let _ = fs::remove_file(&tmp);
        let script = script_do_seletor(&inicial, &tmp.to_string_lossy());
        // Sem -STA o FolderBrowserDialog nao abre: ele exige apartamento de
        // thread unica. E sem -NonInteractive de proposito -- aqui a interacao
        // com o usuario E o objetivo.
        let saida = Command::new("powershell")
            .args(["-NoProfile", "-STA", "-Command", &script])
            .output()
            .map_err(|e| e.to_string())?;
        if !saida.status.success() {
            let _ = fs::remove_file(&tmp);
            return Err(String::from_utf8_lossy(&saida.stderr).trim().to_string());
        }
        let escolhido = fs::read_to_string(&tmp).unwrap_or_default();
        let _ = fs::remove_file(&tmp);
        return Ok(escolhido.trim().to_string());
    }
    #[cfg(not(target_os = "windows"))]
    {
        Err("seletor de pasta nao implementado nesta plataforma".into())
    }
}

/// Olha uma pasta ANTES de vincular: ha um biblioteca.txt? da para ler? o que
/// tem dentro?
///
/// Devolve o CONTEUDO, nao uma contagem. Quem conta os livros e a mesma
/// `parseTSV` da pagina que vai carrega-los — uma contagem feita aqui seria um
/// SEGUNDO leitor de TSV, e dois leitores divergem: ate a 1.9.13 uma linha com
/// 9 campos entrava no arquivo e era descartada em silencio. O numero que o
/// usuario le na pergunta tem de ser o numero que ele vai ver na tela.
#[tauri::command]
fn olhar_pasta(caminho: String) -> String {
    olhar(Path::new(caminho.trim()))
}

/// O corpo do `olhar_pasta`, sem o Tauri em volta — e o que os testes exercitam.
fn olhar(pasta: &Path) -> String {
    let pasta = pasta.to_path_buf();
    let nome = pasta
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| pasta.to_string_lossy().to_string());
    let resposta = |tem: bool, conteudo: String, erro: String| {
        serde_json::json!({
            "nome": nome,
            "caminho": pasta.to_string_lossy(),
            "temArquivo": tem,
            "conteudo": conteudo,
            "erro": erro,
        })
        .to_string()
    };
    if !pasta.is_dir() {
        return resposta(false, String::new(), format!("A pasta não existe: {}", pasta.display()));
    }
    let arquivo = pasta.join("biblioteca.txt");
    // `exists()` tambem e verdadeiro para um DIRETORIO chamado biblioteca.txt.
    // Isso e de proposito: ha arquivo no caminho, so nao da para ler — e o
    // caminho certo entao e avisar, nunca criar por cima.
    if !arquivo.exists() {
        return resposta(false, String::new(), String::new());
    }
    match ler_com_retentativa(&arquivo) {
        Ok(texto) => resposta(true, texto, String::new()),
        Err(e) => resposta(true, String::new(), e),
    }
}

/// Cria o biblioteca.txt na pasta e passa a usa-la.
///
/// NAO SOBRESCREVE: se o arquivo apareceu entre o `olhar_pasta` e esta chamada,
/// devolve o erro `ja_existe` e quem chama volta ao ramo "achei uma
/// biblioteca". Alguns provedores de nuvem baixam renomeando para
/// "biblioteca (1).txt" e depois trocam os dois; sem esta checagem o app
/// poderia zerar o arquivo de alguem no intervalo.
///
/// Escreve o arquivo ANTES de gravar o pasta.txt. Na ordem inversa, uma falha
/// de escrita deixaria o app apontado para uma pasta sem biblioteca — e
/// `pastas_candidatas()` cairia na proxima da lista, que e outra biblioteca.
#[tauri::command]
fn criar_na_pasta(caminho: String, conteudo: String) -> Result<String, String> {
    let pasta = PathBuf::from(caminho.trim());
    let arquivo = criar_arquivo_na_pasta(&pasta, &conteudo)?;
    gravar_pasta_configurada(&pasta)?;
    Ok(arquivo.to_string_lossy().to_string())
}

/// Cria o arquivo e devolve o caminho dele. Separado do `criar_na_pasta` para
/// que os testes exercitem a parte que pode PERDER dado sem escrever no
/// pasta.txt da maquina de quem roda os testes.
fn criar_arquivo_na_pasta(pasta: &Path, conteudo: &str) -> Result<PathBuf, String> {
    if !pasta.is_dir() {
        return Err(format!("A pasta não existe: {}", pasta.display()));
    }
    let arquivo = pasta.join("biblioteca.txt");
    if arquivo.exists() {
        return Err("ja_existe".to_string());
    }
    fs::write(&arquivo, conteudo).map_err(|e| e.to_string())?;
    Ok(arquivo)
}

/// Le o TSV completo. Retorna "" se o arquivo nao existir.
#[tauri::command]
fn carregar_tsv() -> String {
    let caminho = caminho_base();
    if !caminho.exists() {
        return String::new();
    }
    ler_com_retentativa(&caminho).unwrap_or_default()
}

/// Grava o TSV, sobrescrevendo biblioteca.txt.
#[tauri::command]
fn salvar_tsv(conteudo: String) -> Result<(), String> {
    let path = caminho_base();
    backup_automatico(&path, MAX_BACKUP_TXT, &BACKUP_TXT_FEITO);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    fs::write(&path, conteudo).map_err(|e| e.to_string())
}

/// Le biblioteca.dat (JSON de fotos). Marca a sessao como "dat lido" em caso de
/// sucesso — ou quando o arquivo comprovadamente nao existe, caso em que gravar
/// e criar, nao sobrescrever.
#[tauri::command]
fn carregar_fotos() -> String {
    let caminho = caminho_dat();
    if !caminho.exists() {
        DAT_LIDO.store(true, Ordering::SeqCst);
        return String::new();
    }
    match ler_com_retentativa(&caminho) {
        Ok(conteudo) => {
            DAT_LIDO.store(true, Ordering::SeqCst);
            conteudo
        }
        Err(_) => {
            // Falhou a leitura de um arquivo que EXISTE: nao liberar a gravacao.
            DAT_LIDO.store(false, Ordering::SeqCst);
            String::new()
        }
    }
}

/// Grava o JSON de fotos em biblioteca.dat — apenas se o arquivo ja foi lido
/// nesta sessao. Caso contrario recusa, para nao apagar fotos existentes.
#[tauri::command]
fn salvar_fotos(conteudo: String) -> Result<(), String> {
    if !DAT_LIDO.load(Ordering::SeqCst) {
        return Err(
            "As fotos ainda não foram lidas do arquivo nesta sessão; \
             gravar agora poderia apagar fotos existentes. \
             Use Recarregar e tente de novo."
                .to_string(),
        );
    }
    let path = caminho_dat();
    backup_automatico(&path, MAX_BACKUP_DAT, &BACKUP_DAT_FEITO);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    fs::write(&path, conteudo).map_err(|e| e.to_string())
}

/// Caminho completo de biblioteca.txt, para exibir na interface.
#[tauri::command]
fn obter_caminho_arquivo() -> String {
    caminho_base().to_string_lossy().to_string()
}

/// O caminho, a DATA do arquivo e se a pasta em uso e a que foi configurada.
///
/// POR QUE A DATA: em 13/10/2026 o aplicativo do Windows mostrou "0 livros com
/// pais" e 749 livros, quando a base tinha 750 e 280 paises. Nao havia defeito
/// no programa: o iCloud para Windows havia parado de sincronizar e o arquivo
/// daquela pasta era de SEIS DIAS antes. A faixa ja mostrava o caminho, mas
/// caminho nao conta idade — e nuvem que para de sincronizar para em silencio.
///
/// POR QUE O AVISO DE PASTA: se ha uma pasta configurada e ela some (a maquina
/// esta fora da rede, o disco externo nao esta montado), a busca automatica
/// escolhe outra e o usuario passa a ver OUTRA biblioteca sem ser avisado. Foi
/// exatamente assim que a copia velha entrou em cena.
#[tauri::command]
fn info_do_arquivo() -> String {
    let caminho = caminho_base();
    let modificado = fs::metadata(&caminho)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| time::OffsetDateTime::from(t).format(
            &time::format_description::well_known::Rfc3339).ok())
        .unwrap_or_default();
    // O TEXTO configurado, nao a pasta resolvida: quando a pasta nao existe,
    // `pasta_configurada()` devolve None, `configurada` ficava vazia e o
    // `usando_configurada` abaixo concluia que estava tudo bem — deixando a
    // faixa de ATENCAO da pagina inalcancavel justamente no caso que ela
    // existe para cobrir.
    let configurada = pasta_configurada_texto().unwrap_or_default();
    let usando_configurada = configurada.is_empty()
        || caminho.parent().map(|p| p.to_string_lossy().to_string()) == Some(configurada.clone());
    serde_json::json!({
        "caminho": caminho.to_string_lossy(),
        "modificado": modificado,
        "configurada": configurada,
        "usandoConfigurada": usando_configurada,
    })
    .to_string()
}

/// Copia de backup: biblioteca_<sufixo>.txt na mesma pasta.
#[tauri::command]
fn fazer_backup(sufixo: String) -> Result<String, String> {
    let origem = caminho_base();
    if !origem.exists() {
        return Err("Arquivo biblioteca.txt não encontrado.".to_string());
    }
    let pasta = origem.parent().unwrap_or_else(|| Path::new("."));
    let destino = pasta.join(format!("biblioteca_{}.txt", sufixo));
    fs::copy(&origem, &destino).map_err(|e| e.to_string())?;
    Ok(destino.to_string_lossy().to_string())
}

/// Fecha a janela principal.
#[tauri::command]
fn fechar_janela(window: tauri::Window) -> Result<(), String> {
    window.close().map_err(|e| e.to_string())
}

/// O navegador que o usuario escolheu para `https`, lido do registro, com a
/// linha de comando ja montada para este endereco.
///
/// Caminho: HKCU\…\UrlAssociations\https\UserChoice -> ProgId, e dai
/// HKCR\<ProgId>\shell\open\command, que vem como
/// `"C:\…\chrome.exe" --single-argument %1`. O `%1` vira o endereco, e o
/// endereco NUNCA passa por interpretador de linha de comando: vai como
/// argumento, direto ao executavel.
#[cfg(target_os = "windows")]
fn navegador_escolhido(url: &str) -> Option<(String, Vec<String>)> {
    use std::process::Command;

    let valor = |chave: &str, nome: &str| -> Option<String> {
        let mut c = Command::new("reg");
        c.args(["query", chave]);
        if nome.is_empty() { c.arg("/ve"); } else { c.args(["/v", nome]); }
        let saida = c.output().ok()?;
        let texto = String::from_utf8_lossy(&saida.stdout).to_string();
        let linha = texto.lines().find(|l| l.contains("REG_SZ"))?;
        Some(linha.split("REG_SZ").nth(1)?.trim().to_string())
    };

    let progid = valor(
        "HKCU\\SOFTWARE\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\https\\UserChoice",
        "ProgId",
    )?;
    let comando = valor(&format!("HKCR\\{progid}\\shell\\open\\command"), "")?;

    // "C:\…\chrome.exe" --single-argument %1   ->   exe + argumentos
    let (exe, resto) = if let Some(fim) = comando.strip_prefix('"').and_then(|r| r.find('"').map(|i| (r[..i].to_string(), r[i + 1..].to_string()))) {
        fim
    } else {
        let mut partes = comando.splitn(2, ' ');
        (partes.next()?.to_string(), partes.next().unwrap_or("").to_string())
    };

    let mut argumentos: Vec<String> = resto
        .split_whitespace()
        .filter(|a| !a.is_empty())
        .map(|a| a.trim_matches('"').to_string())
        .collect();
    match argumentos.iter().position(|a| a == "%1") {
        Some(i) => argumentos[i] = url.to_string(),
        None => argumentos.push(url.to_string()),
    }
    Some((exe, argumentos))
}

/// Esquemas que podemos entregar ao sistema. Lista fechada DE PROPOSITO: o
/// texto vem do campo de comentarios, que o usuario digita, e `file:` ou um
/// esquema inventado por um aplicativo instalado nao tem por que sair daqui.
const ESQUEMAS_PERMITIDOS: [&str; 4] = ["http", "https", "kindle", "mailto"];

/// Abre um endereco no aplicativo que o sistema escolher — o navegador para
/// `https`, o Kindle para `kindle`.
///
/// POR QUE ISTO EXISTE: dentro da janela do Tauri um `<a target="_blank">` nao
/// faz NADA (nao navega, nao abre aplicativo, nao reclama), do mesmo jeito que
/// acontecia no WKWebView do Mac.
///
/// POR QUE PELO POWERSHELL: a primeira versao usava
/// `rundll32 url.dll,FileProtocolHandler`. Medido em 08/10/2026 no Windows do
/// usuario: o `kindle://` abria e o `https://read.amazon.com/?asin=…` nao fazia
/// nada — o FileProtocolHandler se perde com `?` e `&` na consulta. O
/// `Start-Process` nao tem esse problema, e ja se provou nesta maquina na copia
/// para a area de transferencia.
///
/// A URL vai por VARIAVEL DE AMBIENTE, nunca interpolada no comando: ela vem do
/// campo de comentarios, que e texto do usuario, e aspas ali dentro poderiam
/// virar outro comando.
#[tauri::command]
fn abrir_endereco(url: String) -> Result<(), String> {
    let esquema = url.split(':').next().unwrap_or("").to_ascii_lowercase();
    if !ESQUEMAS_PERMITIDOS.contains(&esquema.as_str()) {
        return Err(format!("esquema nao permitido: {esquema}"));
    }
    // Aspas nao existem em endereco legitimo e sao o unico jeito de escapar do
    // argumento no cmd. Sem elas, nada do que vem do comentario vira comando.
    if url.contains('"') || url.chars().any(|c| c.is_control()) {
        return Err("endereco com caractere proibido".into());
    }

    #[cfg(target_os = "windows")]
    {
        use std::process::Command;
        let mut queixas: Vec<String> = Vec::new();

        // 0) O navegador que o usuario escolheu, executado DIRETO.
        //
        // Medido em 09/10/2026: pedir ao sistema "abra este endereco" (o `start`
        // do cmd) com o Windows rodando no Parallels faz o link ser desviado
        // para o macOS, e la ele acaba no VMware Fusion em vez do navegador. A
        // integracao de aplicativos do Parallels nao e nossa para consertar;
        // sair da cadeia de associacoes e.
        //
        // A escolha continua sendo a do usuario: ela vem do registro dele.
        // SO para pagina da web. O `kindle://` tem de continuar indo pelo
        // sistema, senao abriria no navegador — e no Windows ele ja funciona.
        if esquema == "http" || esquema == "https" {
            match navegador_escolhido(&url) {
                Some((exe, argumentos)) => match Command::new(&exe).args(&argumentos).spawn() {
                    Ok(_) => return Ok(()),
                    Err(e) => queixas.push(format!("{exe}: {e}")),
                },
                None => queixas.push("nao achei o navegador no registro".into()),
            }
        }

        // 1) o jeito classico: o `start` do proprio cmd. As aspas protegem o
        //    `&` da consulta, que sem elas partiria o comando em dois.
        match Command::new("cmd")
            .args(["/C", "start", "", url.as_str()])
            .status()
        {
            Ok(st) if st.success() => return Ok(()),
            Ok(st) => queixas.push(format!("cmd start saiu {st}")),
            Err(e) => queixas.push(format!("cmd start: {e}")),
        }

        // 2) PowerShell, com a URL por variavel de ambiente — nunca interpolada.
        match Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command",
                   "Start-Process -FilePath $env:BIBLIOTECA_URL"])
            .env("BIBLIOTECA_URL", &url)
            .output()
        {
            Ok(o) if o.status.success() => return Ok(()),
            Ok(o) => queixas.push(format!(
                "Start-Process: {}", String::from_utf8_lossy(&o.stderr).trim())),
            Err(e) => queixas.push(format!("Start-Process: {e}")),
        }

        // 3) o caminho antigo. Da conta de `kindle://`, mas se perde com `?` e
        //    `&` — foi assim que o link do leitor nao abria nada em 08/10/2026.
        match Command::new("rundll32.exe")
            .arg("url.dll,FileProtocolHandler")
            .arg(&url)
            .spawn()
        {
            Ok(_) => return Ok(()),
            Err(e) => queixas.push(format!("rundll32: {e}")),
        }

        return Err(queixas.join(" | "));
    }

    #[cfg(target_os = "macos")]
    {
        let saida = std::process::Command::new("/usr/bin/open").arg(&url).spawn();
        return saida.map(|_| ()).map_err(|e| e.to_string());
    }
    #[cfg(all(not(target_os = "windows"), not(target_os = "macos")))]
    {
        let saida = std::process::Command::new("xdg-open").arg(&url).spawn();
        saida.map(|_| ()).map_err(|e| e.to_string())
    }
}

/// Poe texto na area de transferencia.
///
/// O aplicativo Kindle abre na biblioteca e nao aceita rota de busca; com o
/// titulo copiado, basta colar na busca dele. Pelo lado nativo porque dentro da
/// janela do WebView a API do navegador nao e confiavel.
///
/// Passa por ARQUIVO em UTF-8 e `Get-Content -Encoding UTF8`, nao por cano para
/// o `clip`: o `clip` interpreta a entrada na pagina de codigo do console, e
/// titulo brasileiro e cheio de acento — "A paixao segundo G. H." sairia torto.
#[tauri::command]
fn copiar_texto(texto: String) -> Result<(), String> {
    if texto.trim().is_empty() {
        return Err("nada a copiar".into());
    }
    #[cfg(target_os = "windows")]
    {
        use std::process::Command;
        let tmp = std::env::temp_dir().join("biblioteca-copiar.txt");
        fs::write(&tmp, texto.as_bytes()).map_err(|e| e.to_string())?;
        let script = format!(
            "Set-Clipboard -Value (Get-Content -Raw -Encoding UTF8 -LiteralPath '{}')",
            tmp.display()
        );
        let saida = Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .output()
            .map_err(|e| e.to_string())?;
        let _ = fs::remove_file(&tmp);
        if !saida.status.success() {
            return Err(String::from_utf8_lossy(&saida.stderr).trim().to_string());
        }
        return Ok(());
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = texto;
        Err("area de transferencia nao implementada nesta plataforma".into())
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            carregar_tsv,
            salvar_tsv,
            carregar_fotos,
            salvar_fotos,
            obter_caminho_arquivo,
            info_do_arquivo,
            fazer_backup,
            fechar_janela,
            diagnosticar,
            listar_pastas_procuradas,
            definir_pasta,
            escolher_pasta,
            olhar_pasta,
            criar_na_pasta,
            iniciar_sessao,
            carregar_removidas,
            registrar_remocoes,
            cancelar_remocoes,
            abrir_endereco,
            copiar_texto,
        ])
        .run(tauri::generate_context!())
        .expect("erro ao iniciar a aplicação Biblioteca");
}

// ---------------------------------------------------------------------------
// Testes
//
// So das duas funcoes do "Selecionar pasta" que mexem em arquivo. O resto do
// fluxo -- os quatro ramos, os textos, a contagem -- e da pagina, e esta
// medido em motor-web/testes/casos/11-selecionar-pasta.spec.js.
//
// Nenhum destes testes toca no pasta.txt da maquina: `criar_arquivo_na_pasta`
// foi separado de `gravar_pasta_configurada` exatamente por isso.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod testes {
    use super::*;

    /// Uma pasta vazia so para este teste, apagada no fim.
    fn pasta_de_teste(nome: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("biblioteca-teste-{}-{}", nome, std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn json(texto: &str) -> serde_json::Value {
        serde_json::from_str(texto).unwrap()
    }

    #[test]
    fn pasta_vazia_nao_tem_arquivo_e_nao_tem_erro() {
        let p = pasta_de_teste("vazia");
        let v = json(&olhar(&p));
        assert_eq!(v["temArquivo"], false);
        assert_eq!(v["erro"], "");
        assert_eq!(v["conteudo"], "");
        let _ = fs::remove_dir_all(&p);
    }

    #[test]
    fn pasta_com_arquivo_devolve_o_conteudo_inteiro() {
        let p = pasta_de_teste("comlivros");
        let tsv = "Titulo\tAutor\tTema\t2020\tEstante\n";
        fs::write(p.join("biblioteca.txt"), tsv).unwrap();
        let v = json(&olhar(&p));
        assert_eq!(v["temArquivo"], true);
        assert_eq!(v["erro"], "");
        // O CONTEUDO, byte a byte: quem conta os livros e a parseTSV da pagina.
        assert_eq!(v["conteudo"], tsv);
        let _ = fs::remove_dir_all(&p);
    }

    #[test]
    fn biblioteca_txt_que_e_pasta_da_erro_e_nao_perde_o_que_esta_la() {
        // O ramo C. Um diretorio chamado biblioteca.txt `exists()`, entao ha
        // "arquivo" no caminho -- so nao da para ler. O certo e avisar.
        let p = pasta_de_teste("quebrada");
        fs::create_dir_all(p.join("biblioteca.txt")).unwrap();
        let v = json(&olhar(&p));
        assert_eq!(v["temArquivo"], true);
        assert_ne!(v["erro"], "");
        // E criar nao pode passar por cima.
        assert_eq!(criar_arquivo_na_pasta(&p, "x"), Err("ja_existe".to_string()));
        assert!(p.join("biblioteca.txt").is_dir());
        let _ = fs::remove_dir_all(&p);
    }

    #[test]
    fn pasta_que_nao_existe_da_erro_nos_dois() {
        let p = std::env::temp_dir().join("biblioteca-teste-inexistente-nunca-criada");
        let _ = fs::remove_dir_all(&p);
        assert_ne!(json(&olhar(&p))["erro"], "");
        assert!(criar_arquivo_na_pasta(&p, "").is_err());
    }

    #[test]
    fn criar_grava_o_conteudo_e_vazio_e_vazio() {
        let p = pasta_de_teste("criar");
        let arq = criar_arquivo_na_pasta(&p, "").unwrap();
        assert_eq!(fs::read_to_string(&arq).unwrap(), "");
        let _ = fs::remove_dir_all(&p);

        let q = pasta_de_teste("criar-com-livros");
        let tsv = "Levado\tAutor\tTema\t1999\tEstante\n";
        let arq = criar_arquivo_na_pasta(&q, tsv).unwrap();
        assert_eq!(fs::read_to_string(&arq).unwrap(), tsv);
        let _ = fs::remove_dir_all(&q);
    }

    #[test]
    fn o_roteiro_do_seletor_nao_usa_aspas_duplas_e_dobra_a_simples() {
        let r = script_do_seletor("C:\\Pasta d'Agua", "C:\\saida.txt");
        assert!(!r.contains('"'), "aspa dupla no roteiro: {}", r);
        assert!(r.contains("'C:\\Pasta d''Agua'"), "aspa simples nao dobrada: {}", r);
    }

    /// O roteiro de verdade, rodado de verdade, sem a linha que esperaria uma
    /// pessoa. Mede a TRAVESSIA — Rust, linha de comando do Windows, PowerShell
    /// — com um caminho que tem espaco e acento. Foi para isto que o caminho
    /// volta por arquivo e nao pela saida padrao: a saida sai na pagina de
    /// codigo do console e "Coleção" volta corrompido.
    #[cfg(target_os = "windows")]
    #[test]
    fn o_roteiro_do_seletor_atravessa_o_powershell() {
        use std::process::Command;
        let pasta = std::env::temp_dir().join("Coleção de Memórias");
        let _ = fs::create_dir_all(&pasta);
        let destino = std::env::temp_dir().join("biblioteca-teste-seletor.txt");
        let _ = fs::remove_file(&destino);

        let script = script_do_seletor(&pasta.to_string_lossy(), &destino.to_string_lossy())
            .replace("$d.ShowDialog() -eq 'OK'", "$true");
        let saida = Command::new("powershell")
            .args(["-NoProfile", "-STA", "-Command", &script])
            .output()
            .expect("powershell");
        assert!(saida.status.success(), "{}", String::from_utf8_lossy(&saida.stderr));

        let bytes = fs::read(&destino).expect("o roteiro nao gravou nada");
        // Sem BOM: um pasta.txt com BOM foi o defeito de 03/11/2026.
        assert_ne!(&bytes[0..3], &b"\xef\xbb\xbf"[..]);
        assert_eq!(String::from_utf8(bytes).unwrap(), pasta.to_string_lossy());

        let _ = fs::remove_file(&destino);
        let _ = fs::remove_dir_all(&pasta);
    }

    #[test]
    fn criar_nunca_sobrescreve_biblioteca_existente() {
        // A corrida da proposta: o arquivo apareceu entre o olhar e o criar.
        // Alguns provedores de nuvem baixam renomeando e depois trocam os dois.
        let p = pasta_de_teste("corrida");
        fs::write(p.join("biblioteca.txt"), "o que ja estava la").unwrap();
        assert_eq!(criar_arquivo_na_pasta(&p, ""), Err("ja_existe".to_string()));
        assert_eq!(
            fs::read_to_string(p.join("biblioteca.txt")).unwrap(),
            "o que ja estava la"
        );
        let _ = fs::remove_dir_all(&p);
    }
}
