use docker_control::utils::platform;

#[test]
fn test_get_brew_prefix() {
    let prefix = platform::get_brew_prefix();
    if prefix.is_some() {
        println!("Brew prefix found: {}", prefix.unwrap());
    } else {
        println!("Brew prefix not found");
    }
}
