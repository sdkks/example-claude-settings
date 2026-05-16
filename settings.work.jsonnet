// Work-specific config example
// Restore with: make restore-config  (requires ENVIRONMENT=work)
// Shows how to add work-specific plugins, marketplaces, and Bedrock config.
// Replace <REDACTED> values with your actual credentials.

{
  "enabledPlugins": {
    "internaltools-service-deploy@example-company-plugins": false,
    "rpi@example-company-plugins": true,
    "example-eng-tools@example-company-plugins": false
  },
  "extraKnownMarketplaces": {
    "example-company-plugins": {
      "source": {
        "source": "github",
        "repo": "example-company/claude-code-marketplace"
      }
    }
  },
  "env": {
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "true",
    "CLAUDE_CODE_USE_BEDROCK": "true",
    "ANTHROPIC_AUTH_TOKEN": "<REDACTED>",
    "ANTHROPIC_BEDROCK_BASE_URL": "https://ai-gateway.example.com/bedrock"
  },
  "model": "us.anthropic.claude-sonnet-4-6"
}
