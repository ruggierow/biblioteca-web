use std::fs;
use std::path::PathBuf;

/// Caminho para biblioteca.txt.
/// No Windows, dirs::document_dir() já segue o redirecionamento do OneDrive
/// automaticamente (aponta para a pasta Documents real do usuário).
fn caminho_base() -> PathBuf {
    if let Some(docs) = dirs::document_dir() {
        let p = docs.join("biblioteca.txt");
        return p;
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("biblioteca.txt")
}

/// Caminho para biblioteca.dat — mesmo diretório que biblioteca.txt.
fn caminho_dat() -> PathBuf {
    caminho_base().with_extension("dat")
}

/// Lê o TSV completo e retorna como string. Retorna "" se o arquivo não existir.
#[tauri::command]
fn carregar_tsv() -> String {
    match fs::read_to_string(caminho_base()) {
        Ok(conteudo) => conteudo,
        Err(_) => String::new(),
    }
}

/// Grava o TSV recebido do frontend, sobrescrevendo biblioteca.txt.
#[tauri::command]
fn salvar_tsv(conteudo: String) -> Result<(), String> {
    let path = caminho_base();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    fs::write(&path, conteudo).map_err(|e| e.to_string())
}

/// Lê biblioteca.dat (JSON de fotos) e retorna como string. Retorna "" se não existir.
#[tauri::command]
fn carregar_fotos() -> String {
    match fs::read_to_string(caminho_dat()) {
        Ok(conteudo) => conteudo,
        Err(_) => String::new(),
    }
}

/// Grava o JSON de fotos recebido do frontend em biblioteca.dat.
#[tauri::command]
fn salvar_fotos(conteudo: String) -> Result<(), String> {
    let path = caminho_dat();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    fs::write(&path, conteudo).map_err(|e| e.to_string())
}

/// Retorna o caminho completo de biblioteca.txt para exibir na interface.
#[tauri::command]
fn obter_caminho_arquivo() -> String {
    caminho_base().to_string_lossy().to_string()
}

/// Cria uma cópia de backup: biblioteca_<sufixo>.txt no mesmo diretório.
#[tauri::command]
fn fazer_backup(sufixo: String) -> Result<String, String> {
    let origem = caminho_base();
    if !origem.exists() {
        return Err("Arquivo biblioteca.txt não encontrado.".to_string());
    }
    let pasta = origem.parent().unwrap_or_else(|| std::path::Path::new("."));
    let destino = pasta.join(format!("biblioteca_{}.txt", sufixo));
    fs::copy(&origem, &destino).map_err(|e| e.to_string())?;
    Ok(destino.to_string_lossy().to_string())
}

/// Fecha a janela principal do app.
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
        ])
        .run(tauri::generate_context!())
        .expect("erro ao iniciar a aplicação Biblioteca");
}
