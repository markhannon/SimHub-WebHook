# Project general coding guidelines

## Code Style
- Use semantic HTML5 elements (header, main, section, article, etc.)
- Prefer modern JavaScript (ES6+) features like const/let, arrow functions, and template literals

## Naming Conventions
- Use PascalCase for component names, interfaces, and type aliases
- Use camelCase for variables, functions, and methods
- Prefix private class members with underscore (_)
- Use ALL_CAPS for constants

## Code Quality
- Use meaningful variable and function names that clearly describe their purpose
- Include helpful comments for complex logic
- Add error handling for user inputs and API calls
- Write unit tests for critical functions and components
- Follow the DRY (Don't Repeat Yourself) principle to avoid code duplication

# PowerShell Coding Guidelines
- Maintain compatibility with PowerShell 5.1 and later versions.
- Follow PowerShell PascalCase conventions for all functions and parameters.
- Use [CmdletBinding()] in all scripts.
- Use Begin, Process, and End blocks for pipeline functions.
- Return raw objects, not formatted strings.
- Use standard parameters (e.g., -Path, -Force).
- Avoid aliases unless specifically requested.
- Prefer ValidateSet over generic type validation where appropriate.
