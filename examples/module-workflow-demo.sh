#!/bin/bash

# Demo script showing the new module support functionality
# This script demonstrates how to use the release and merge commands with vendor modules

set -e

echo "=== Docker Control Plugin - Module Support Demo ==="
echo

# Check if we're in a docker control project
if [[ ! -f ".managed-by-docker-control" ]]; then
    echo "❌ This demo must be run from a docker control managed project directory"
    echo "   Please run 'docker control init' first to create a project"
    exit 1
fi

echo "✅ Found docker control managed project"
echo

# Create example vendor module structure
echo "📁 Setting up example vendor module structure..."
mkdir -p htdocs/vendor/ik/shared
mkdir -p htdocs/vendor/example/library

# Initialize Git repositories in the modules
echo "🔧 Initializing Git repositories in vendor modules..."

# Create ik/shared module
cd htdocs/vendor/ik/shared
git init
echo "# IK Shared Library" > README.md
echo "version: 1.0.0" > VERSION
git add .
git config user.name "Demo User"
git config user.email "demo@example.com"
git commit -m "Initial commit for ik/shared module"
cd ../../../../

# Create example/library module  
cd htdocs/vendor/example/library
git init
echo "# Example Library" > README.md
echo "version: 0.1.0" > VERSION
git add .
git config user.name "Demo User"
git config user.email "demo@example.com"
git commit -m "Initial commit for example/library module"
cd ../../../../

echo "✅ Created example vendor modules with Git repositories"
echo

# Show the new help documentation
echo "📖 Help documentation showing module support in release/merge commands:"
echo "================================================================"
docker control release --help | grep -A 5 "Arguments:"
docker control merge --help | grep -A 5 "Arguments:"
echo

# Demonstrate module validation
echo "🔍 Testing module validation..."
echo

echo "Testing valid module path:"
echo "  docker control release ik/shared"
echo "  (This would create a release for the ik/shared module)"
echo

echo "Testing invalid module path:"
echo "  docker control release ../invalid/path"
echo "  (This would fail with validation error)"
echo

echo "Testing non-existent module:"
echo "  docker control release non/existent"
echo "  (This would fail because the module doesn't exist)"
echo

echo "Testing module without Git repository:"
mkdir -p htdocs/vendor/no/git
echo "  docker control release no/git"
echo "  (This would fail because the directory is not a Git repository)"
echo

# Show directory structure
echo "📂 Current vendor module structure:"
echo "=================================="
find htdocs/vendor -type d -name ".git" | sed 's|htdocs/vendor/||' | sed 's|/.git||' | sort | while read module; do
    echo "  ✅ $module (Git repository)"
done
echo

# Show worktree paths that would be created
echo "🏗️  Worktree paths for module operations:"
echo "========================================"
echo "  Main project:     releases/"
echo "  ik/shared module: releases/vendor/ik/shared/"
echo "  example/library:  releases/vendor/example/library/"
echo

echo "🎯 Example usage commands:"
echo "========================="
echo "  # Create release for main project (existing functionality)"
echo "  docker control release"
echo
echo "  # Create release for ik/shared module (new functionality)"
echo "  docker control release ik/shared"
echo
echo "  # Merge release for main project (existing functionality)"
echo "  docker control merge"
echo
echo "  # Merge release for example/library module (new functionality)"
echo "  docker control merge example/library"
echo

echo "✨ Module support has been successfully added to the Docker Control Plugin!"
echo "   You can now manage releases and merges for vendor modules independently."
echo

# Clean up demo files
echo "🧹 Cleaning up demo files..."
rm -rf htdocs/vendor/ik htdocs/vendor/example htdocs/vendor/no
echo "✅ Demo completed successfully!"
