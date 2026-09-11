// Binario auxiliar: imprime onde o app Biblioteca vai procurar os arquivos.
//
// Existe porque a resolucao de caminhos depende do PERFIL DO USUARIO, e um
// comando rodado como SYSTEM (por exemplo via `prlctl exec`) veria
// C:\WINDOWS\system32\config\systemprofile em vez de C:\Users\<voce>.
// Rodando este binario na sessao do usuario, ve-se exatamente o que o app ve.
//
// Nao entra no pacote do app: so e compilado sob demanda com
//     cargo build --release --bin diagnostico
//
// Uso:  diagnostico.exe            imprime na tela
//       diagnostico.exe saida.txt  grava num arquivo

use std::env;
use std::fs;

fn main() {
    let texto = biblioteca_tauri_lib::diagnostico_texto();

    match env::args().nth(1) {
        Some(destino) => {
            if let Err(e) = fs::write(&destino, &texto) {
                eprintln!("Erro ao gravar {}: {}", destino, e);
                std::process::exit(1);
            }
        }
        None => println!("{}", texto),
    }
}
