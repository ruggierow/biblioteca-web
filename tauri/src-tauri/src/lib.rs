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

/// Pasta configurada manualmente, se houver e se ainda existir.
fn pasta_configurada() -> Option<PathBuf> {
    let cfg = arquivo_config()?;
    let texto = fs::read_to_string(cfg).ok()?;
    let caminho = PathBuf::from(texto.trim());
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

/// Define manualmente a pasta a usar. Passe "" para voltar ao automatico.
#[tauri::command]
fn definir_pasta(caminho: String) -> Result<String, String> {
    let cfg = arquivo_config().ok_or("Não foi possível determinar a pasta de configuração.")?;
    let pai = cfg.parent().ok_or("Caminho de configuração inválido.")?;
    fs::create_dir_all(pai).map_err(|e| e.to_string())?;

    let limpo = caminho.trim().to_string();
    if limpo.is_empty() {
        let _ = fs::remove_file(&cfg);
        return Ok("Voltou à detecção automática.".to_string());
    }
    if !PathBuf::from(&limpo).is_dir() {
        return Err(format!("A pasta não existe: {}", limpo));
    }
    fs::write(&cfg, &limpo).map_err(|e| e.to_string())?;
    // A pasta mudou: o .dat de la ainda nao foi lido nesta sessao.
    DAT_LIDO.store(false, Ordering::SeqCst);
    Ok(limpo)
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            carregar_tsv,
            salvar_tsv,
            carregar_fotos,
            salvar_fotos,
            obter_caminho_arquivo,
            fazer_backup,
            fechar_janela,
            diagnosticar,
            listar_pastas_procuradas,
            definir_pasta,
            iniciar_sessao,
            carregar_removidas,
            registrar_remocoes,
        ])
        .run(tauri::generate_context!())
        .expect("erro ao iniciar a aplicação Biblioteca");
}
