use docker_control::commands::release::update_composer_version;
use serde_json::Value;
use std::fs;

#[test]
fn test_update_composer_version() -> anyhow::Result<()> {
    let root = std::env::temp_dir().join("docker-control-test-composer");
    if root.exists() {
        fs::remove_dir_all(&root)?;
    }
    fs::create_dir_all(&root)?;

    let composer_path = root.join("composer.json");

    // Test with .x version
    let initial_json = r#"{"name": "test/project", "version": "1.0.0"}"#;
    fs::write(&composer_path, initial_json)?;

    update_composer_version(&root, "9.0.x")?;

    let updated_content = fs::read_to_string(&composer_path)?;
    let updated_json: Value = serde_json::from_str(&updated_content)?;
    assert_eq!(updated_json["version"], "9.0.x-dev");

    // Test with tag version (no .x)
    update_composer_version(&root, "9.0.1")?;
    let updated_content = fs::read_to_string(&composer_path)?;
    let updated_json: Value = serde_json::from_str(&updated_content)?;
    assert_eq!(updated_json["version"], "9.0.1");

    // Test with already -dev version
    update_composer_version(&root, "9.0.x-dev")?;
    let updated_content = fs::read_to_string(&composer_path)?;
    let updated_json: Value = serde_json::from_str(&updated_content)?;
    assert_eq!(updated_json["version"], "9.0.x-dev");

    // Cleanup
    let _ = fs::remove_dir_all(&root);

    Ok(())
}
