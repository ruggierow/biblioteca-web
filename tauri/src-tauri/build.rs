use std::path::Path;

fn main() {
    // No Windows o symlink src/index.html não funciona:
    // copia biblioteca.html → src/index.html antes de cada build.
    // No Mac o symlink já funciona, então pulamos a cópia.
    let destino = Path::new("../src/index.html");
    let eh_symlink = destino.symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false);

    if !eh_symlink {
        let origem = Path::new("../../biblioteca.html");
        if origem.exists() {
            std::fs::copy(origem, destino).expect("Falha ao copiar biblioteca.html para src/index.html");
        }
    }

    tauri_build::build()
}
