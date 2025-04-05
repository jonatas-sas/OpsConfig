return {
  -- NOTE:  Executa linters assíncronos no Neovim sem necessidade de LSP.
  --  Suporte a múltiplos linters e configuração por arquivo ou global.
  --  Integra-se com autocmds para linting automático ao salvar arquivos.
  --  Extensível e compatível com diversas linguagens.
  --  Repositório: https://github.com/mfussenegger/nvim-lint
  'mfussenegger/nvim-lint',

  enabled = vim.g.opsconfig.plugins.nvim_lint,

  event = { 'BufReadPre', 'BufNewFile' },

  config = function()
    local lint = require('lint')

    -- Available Linters {{{

    local linters = {}
    local php_linters = {}

    if vim.g.opsconfig.global.is_dev then
      linters = {
        go = {},
        javascript = { 'eslint_d' },
        typescript = { 'eslint_d' },
        javascriptreact = { 'eslint_d' },
        typescriptreact = { 'eslint_d' },
        svelte = { 'eslint_d' },
        python = { 'pylint' },
        php = php_linters,
      }

      if vim.g.opsconfig.global.languages.go.linter then
        table.insert(linters.go, 'golangci_lint')
      end

      if vim.g.opsconfig.global.linters.enable_phpstan then
        table.insert(php_linters, 'phpstan')
      end

      if vim.g.opsconfig.global.linters.phpcs then
        table.insert(php_linters, 'phpcs')
      end

      if vim.g.opsconfig.global.linters.phpmd then
        table.insert(php_linters, 'phpmd')
      end
    end

    lint.linters_by_ft = linters

    -- }}}

    local lint_augroup = vim.api.nvim_create_augroup('lint', { clear = true })

    vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave' }, {
      group = lint_augroup,
      callback = function()
        lint.try_lint()
      end,
    })

    -- Go Linters {{{

    if vim.g.opsconfig.global.is_dev and vim.g.opsconfig.global.languages.go.linter then
      lint.linters.golangci_lint = {
        name = 'GolangCI-Lint',
        cmd = 'golangci-lint',
        stdin = false,
        append_filename = true,
        args = {
          'run',
          '--output.json.path',
          'stdout',
          '--show-stats=false',
        },
        stream = 'stdout',
        ignore_exitcode = true,
        parser = function(output, bufnr)
          local diagnostics = {}

          local ok, decoded = pcall(vim.fn.json_decode, output)
          if not ok or not decoded or type(decoded.Issues) ~= 'table' then
            return diagnostics
          end

          local severities = {
            ['error'] = vim.diagnostic.severity.ERROR,
            ['warning'] = vim.diagnostic.severity.WARN,
            ['info'] = vim.diagnostic.severity.INFO,
            ['hint'] = vim.diagnostic.severity.HINT,
          }

          for _, issue in ipairs(decoded.Issues) do
            local severity = severities[(issue.Severity or ''):lower()] or vim.diagnostic.severity.ERROR

            table.insert(diagnostics, {
              bufnr = bufnr,
              lnum = issue.Pos.Line - 1,
              col = issue.Pos.Column - 1,
              end_lnum = issue.Pos.Line - 1,
              end_col = issue.Pos.Column,
              source = issue.FromLinter or 'golangci-lint',
              message = issue.Text or 'Unknown issue',
              severity = severity,
            })
          end

          return diagnostics
        end,
      }
    end

    -- }}}

    -- PHP Linters {{{

    -- Configuração do PHPStan {{{

    if vim.g.opsconfig.global.is_dev and vim.g.opsconfig.global.linters.enable_phpstan then
      lint.linters.phpstan = {
        name = 'PHPStan',
        cmd = 'phpstan',
        stdin = false,
        append_filename = true,
        args = {
          'analyse',
          '--error-format=json',
          '--level=max',
          '--no-progress',
          '--no-interaction',
        },
        ignore_exitcode = true,
        parser = function(output, bufnr)
          if output == nil or output == '' then
            return {}
          end

          local decoded = vim.fn.json_decode(output)

          if not decoded or not decoded.files then
            return {}
          end

          local diagnostics = {}

          for _, file in pairs(decoded.files) do
            for _, message in ipairs(file.messages) do
              local severity = vim.diagnostic.severity.WARN

              if message.message:match('error') then
                severity = vim.diagnostic.severity.ERROR
              elseif message.message:match('deprecated') then
                severity = vim.diagnostic.severity.WARN
              elseif message.message:match('notice') or message.message:match('info') then
                severity = vim.diagnostic.severity.INFO
              end

              table.insert(diagnostics, {
                bufnr = bufnr,
                lnum = message.line - 1,
                col = 0,
                message = '[PHPStan] ' .. message.message,
                severity = severity,
                source = 'phpstan',
              })
            end
          end

          return diagnostics
        end,
      }
    end

    -- }}}

    -- Configuração do PHPCS (PSR-12) {{{

    if vim.g.opsconfig.global.is_dev and vim.g.opsconfig.global.linters.enable_phpcs then
      lint.linters.phpcs = {
        name = 'PHPCS',
        cmd = 'phpcs',
        stdin = false,
        append_filename = true,
        args = {
          '--standard=PSR12',
          '--report=json',
        },
        ignore_exitcode = true,
        parser = function(output, bufnr)
          local decoded = vim.fn.json_decode(output)
          local diagnostics = {}

          if decoded and decoded.files then
            for _, file in pairs(decoded.files) do
              for _, message in ipairs(file.messages) do
                table.insert(diagnostics, {
                  bufnr = bufnr,
                  lnum = message.line - 1,
                  col = message.column - 1,
                  message = '[PHPCS] ' .. message.message,
                  severity = message.type == 'ERROR' and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN,
                  source = 'phpcs',
                })
              end
            end
          end

          return diagnostics
        end,
      }
    end

    -- }}}

    -- Configuração do PHP-MD (Code Smells) {{{

    if vim.g.opsconfig.global.is_dev and vim.g.opsconfig.global.linters.enable_phpmd then
      lint.linters.phpmd = {
        name = 'PHPMD',
        cmd = 'phpmd',
        stdin = false,
        append_filename = true,
        args = { vim.fn.expand('%:p'), 'json', 'cleancode,codesize,unusedcode' },
        ignore_exitcode = true,
        parser = function(output, bufnr)
          local decoded = vim.fn.json_decode(output)
          local diagnostics = {}

          if decoded and decoded.violations then
            for _, violation in ipairs(decoded.violations) do
              table.insert(diagnostics, {
                bufnr = bufnr,
                lnum = violation.beginLine - 1,
                col = 0,
                message = '[PHP-MD] ' .. violation.description,
                severity = vim.diagnostic.severity.WARN,
                source = 'phpmd',
              })
            end
          end

          return diagnostics
        end,
      }
    end
    -- }}}

    -- Keymaps {{{

    vim.keymap.set('n', '<leader>lf', function()
      lint.try_lint()
    end, { desc = 'Trigger [L]inting for Current [F]ile' })

    -- }}}
  end,
}
