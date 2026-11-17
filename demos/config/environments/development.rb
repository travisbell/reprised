# frozen_string_literal: true

DemosApplication.configure do
  # Reloads the app before the next request, after one of its files changes.
  config.reload = true
  config.reload_files = ["*.rb", "components/**/*.rb", "controllers/**/*.rb"]
  config.editor = :vscode # the exception page's links to files
end
