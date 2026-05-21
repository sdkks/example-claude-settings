SETTINGS := settings.json
EXAMPLE  := settings.json.example
WORK     := settings.work.jsonnet
HOME_CFG := settings.home.jsonnet
COMMON   := common.jsonnet
SANITIZE := scripts/sanitize-settings.sh
SAVE_WORK := scripts/save-work-config.sh
SAVE_HOME := scripts/save-home-config.sh
SAVE_COMMON := scripts/save-common-config.sh
RESTORE  := scripts/restore-config.sh

.PHONY: all sanitize save-config save-common-config save-work-config save-home-config restore-config commit-push

all: commit-push

save-config: $(SETTINGS)
	@if [ -z "$(ENVIRONMENT)" ]; then \
	  echo "ERROR: ENVIRONMENT is not set. Set ENVIRONMENT=work or ENVIRONMENT=home." >&2; exit 1; fi
	@$(MAKE) save-common-config
	@if [ "$(ENVIRONMENT)" = "work" ]; then $(MAKE) save-work-config; \
	elif [ "$(ENVIRONMENT)" = "home" ]; then $(MAKE) save-home-config; \
	else echo "ERROR: ENVIRONMENT must be 'work' or 'home'" >&2; exit 1; fi

save-common-config: $(SETTINGS)
	@chmod +x $(SAVE_COMMON)
	@$(SAVE_COMMON)

save-work-config: $(SETTINGS)
	@chmod +x $(SAVE_WORK)
	@$(SAVE_WORK)

save-home-config: $(SETTINGS)
	@chmod +x $(SAVE_HOME)
	@$(SAVE_HOME)

sanitize: $(SETTINGS)
	@chmod +x $(SANITIZE)
	$(SANITIZE) < $(SETTINGS) > $(EXAMPLE)
	@echo "Wrote sanitized config to $(EXAMPLE)"

restore-config:
	@chmod +x $(RESTORE)
	$(RESTORE)

commit-push: save-config sanitize
	@if [ -z "$(ENVIRONMENT)" ]; then \
	  echo "ERROR: ENVIRONMENT is not set. Set ENVIRONMENT=work or ENVIRONMENT=home." >&2; exit 1; fi
	git add -u
	git add $(EXAMPLE) $(COMMON)
	@if [ "$(ENVIRONMENT)" = "work" ]; then \
	  git add $(WORK); \
	elif [ "$(ENVIRONMENT)" = "home" ]; then \
	  git add $(HOME_CFG); \
	else \
	  echo "ERROR: ENVIRONMENT must be 'work' or 'home'" >&2; exit 1; fi
	git commit -m "chore: update configs"
	git push
