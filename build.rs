pub fn main() -> std::io::Result<()> {
    ocaml_build::Sigs::new("src/kiosk_project.ml").generate()
}
