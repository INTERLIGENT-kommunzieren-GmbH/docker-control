use docker_control::git::{compare_versions, GitService, is_release_branch_name};
use git2::{BranchType, Repository};
use std::fs;
use std::path::Path;

fn setup_repo(path: &Path) -> Repository {
    if path.exists() {
        fs::remove_dir_all(path).unwrap();
    }
    fs::create_dir_all(path).unwrap();
    let repo = Repository::init(path).unwrap();

    // Create initial commit
    {
        let signature = repo.signature().unwrap();
        let tree_id = repo.index().unwrap().write_tree().unwrap();
        let tree = repo.find_tree(tree_id).unwrap();
        repo.commit(
            Some("HEAD"),
            &signature,
            &signature,
            "Initial commit",
            &tree,
            &[],
        )
        .unwrap();
    }

    repo
}

#[test]
fn test_create_worktree_existing_branch() {
    let root = std::env::temp_dir().join("docker-control-test-existing");
    let repo = setup_repo(&root);
    let git = GitService::from_repo(repo);

    // Create a branch
    let head = git.repo().head().unwrap().peel_to_commit().unwrap();
    git.repo().branch("8.0.x", &head, false).unwrap();

    // Create worktree for existing branch
    let wt_path = root.join("wt-8.0.x");
    let result = git.create_worktree("8.0.x", &wt_path, Some("8.0.x"));

    assert!(
        result.is_ok(),
        "Failed to create worktree for existing branch: {:?}",
        result.err()
    );
    assert!(wt_path.exists());
    assert!(wt_path.join(".git").exists());

    // Cleanup
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn test_create_worktree_new_branch_from_checked_out() {
    let root = std::env::temp_dir().join("docker-control-test-checked-out");
    let repo = setup_repo(&root);
    let git = GitService::from_repo(repo);

    // Current branch is 'master' or 'main' (already checked out in setup_repo)
    let head_branch = git.get_current_branch().unwrap();

    // Create worktree for new branch based on head_branch
    let wt_path = root.join("wt-from-main");
    let result = git.create_worktree("9.0.x", &wt_path, Some(&head_branch));

    assert!(
        result.is_ok(),
        "Failed to create worktree from checked out branch: {:?}",
        result.err()
    );
    assert!(wt_path.exists());
    assert!(git.repo().find_branch("9.0.x", BranchType::Local).is_ok());

    // Cleanup
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn test_list_release_branches_sorting() {
    let root = std::env::temp_dir().join("docker-control-test-sort-branches");
    let repo = setup_repo(&root);
    let git = GitService::from_repo(repo);

    let head = git.repo().head().unwrap().peel_to_commit().unwrap();
    git.repo().branch("1.2.x", &head, false).unwrap();
    git.repo().branch("1.10.x", &head, false).unwrap();
    git.repo().branch("1.1.x", &head, false).unwrap();

    let branches = git.list_release_branches().unwrap();
    assert_eq!(branches, vec!["1.1.x", "1.2.x", "1.10.x"]);

    // Cleanup
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn test_list_tags_sorting() {
    let root = std::env::temp_dir().join("docker-control-test-sort-tags");
    let repo = setup_repo(&root);
    let git = GitService::from_repo(repo);

    let head = git.repo().head().unwrap().peel_to_commit().unwrap();
    let sig = git.repo().signature().unwrap();
    git.repo()
        .tag("1.0.2", head.as_object(), &sig, "Tag 1.0.2", false)
        .unwrap();
    git.repo()
        .tag("1.0.10", head.as_object(), &sig, "Tag 1.0.10", false)
        .unwrap();
    git.repo()
        .tag("1.0.1", head.as_object(), &sig, "Tag 1.0.1", false)
        .unwrap();

    let tags = git.list_tags().unwrap();
    assert_eq!(tags, vec!["1.0.1", "1.0.2", "1.0.10"]);

    // Cleanup
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn test_get_all_commits_from() {
    let root = std::env::temp_dir().join("docker-control-test-commits-from");
    let repo = setup_repo(&root);
    let git = GitService::from_repo(repo);

    // Initial commit is created in setup_repo
    let commits = git.get_all_commits_from("HEAD").unwrap();
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].1, "Initial commit");

    // Add another commit
    {
        let mut index = git.repo().index().unwrap();
        let sig = git.repo().signature().unwrap();
        let tree_id = index.write_tree().unwrap();
        let tree = git.repo().find_tree(tree_id).unwrap();
        let parent = git.repo().head().unwrap().peel_to_commit().unwrap();
        git.repo()
            .commit(Some("HEAD"), &sig, &sig, "Second commit", &tree, &[&parent])
            .unwrap();
    }

    let commits = git.get_all_commits_from("HEAD").unwrap();
    assert_eq!(commits.len(), 2);
    // Ordered by reverse (oldest first) as per get_all_commits_from implementation
    assert_eq!(commits[0].1, "Initial commit");
    assert_eq!(commits[1].1, "Second commit");

    // Cleanup
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn test_is_release_branch_name() {
    assert!(is_release_branch_name("1.0.x"));
    assert!(is_release_branch_name("v1.0.x"));
    assert!(is_release_branch_name("10.12.x"));
    assert!(is_release_branch_name("v10.12.x"));
    assert!(!is_release_branch_name("1.0"));
    assert!(!is_release_branch_name("1.0.0"));
    assert!(!is_release_branch_name("v1.0.0"));
    assert!(!is_release_branch_name("main"));
    assert!(!is_release_branch_name("release/1.0.x"));
}

#[test]
fn test_compare_versions_with_v() {
    use std::cmp::Ordering;
    assert_eq!(compare_versions("1.0.x", "1.1.x"), Ordering::Less);
    assert_eq!(compare_versions("v1.0.x", "1.1.x"), Ordering::Less);
    assert_eq!(compare_versions("1.0.x", "v1.1.x"), Ordering::Less);
    assert_eq!(compare_versions("v1.0.x", "v1.1.x"), Ordering::Less);
    assert_eq!(compare_versions("1.10.x", "1.2.x"), Ordering::Greater);
    assert_eq!(compare_versions("v1.10.x", "v1.2.x"), Ordering::Greater);
}
