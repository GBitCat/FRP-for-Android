# Contributing to FRP Android

Thank you for your interest in contributing to FRP Android! This document provides guidelines and information for contributors.

## How to Contribute

### Reporting Issues
- Use the GitHub issue tracker
- Include detailed steps to reproduce the issue
- Provide device information and Android version
- Include logs if possible

### Suggesting Features
- Open a GitHub issue with the "enhancement" label
- Describe the feature and its use case
- Explain why this feature would be useful

### Code Contributions
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Development Setup

### Prerequisites
- Docker Engine with Compose support
- ADB only when testing a physical device or emulator
- Git

### Setting Up Development Environment
1. Clone the repository.
2. Run `./scripts/install-hooks.sh`.
3. Resolve dependencies with `./docker-dev.sh flutter pub get`.
4. Run tests with `./docker-dev.sh flutter test`.
5. Build with `./docker-dev.sh flutter build apk --debug`.

Pub, Gradle, development HOME, and the Android debug key use persistent Docker
volumes. Do not place release keys, passwords, user backups, real configuration,
or screenshots anywhere in the checkout. The local hook and repository CI
reject sensitive filenames and scan Git history for secrets.

### Code Style
- Follow Kotlin coding conventions
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions small and focused

### Testing
- Write unit tests for new functionality
- Ensure all tests pass in the Docker environment before submitting
- Test on different Android versions if possible

## Pull Request Process

1. Update the README.md if needed
2. Update the CHANGELOG.md with your changes
3. Ensure all tests pass
4. Request review from maintainers
5. Address review comments
6. Get approval from at least one maintainer

## Code of Conduct

### Our Pledge
We are committed to making participation in this project a harassment-free experience for everyone.

### Our Standards
- Using welcoming and inclusive language
- Being respectful of differing viewpoints
- Gracefully accepting constructive criticism
- Focusing on what is best for the community

### Our Responsibilities
Project maintainers are responsible for clarifying standards of acceptable behavior.

## Getting Help

- Open a GitHub issue for bugs or feature requests
- Join our community discussions
- Check the documentation first

## License

By contributing to FRP Android, you agree that your contributions will be licensed under the MIT License.
