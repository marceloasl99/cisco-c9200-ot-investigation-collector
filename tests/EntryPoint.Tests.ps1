BeforeDiscovery {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    $script:callSites = @()
    $libFunctions = @{}
    foreach ($lib in Get-ChildItem (Join-Path $ProjectRoot 'lib') -Filter *.ps1) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($lib.FullName, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $names = @()
            $pb = $fn.Body.ParamBlock
            if ($pb) { $names = @($pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
            $libFunctions[$fn.Name] = $names
        }
    }
    foreach ($rel in 'CiscoC9200-OT-Investigation.ps1', 'gui/Gui.ps1') {
        $path = Join-Path $ProjectRoot $rel
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $calls) {
            $cmd = $c.GetCommandName()
            if (-not $cmd -or -not $libFunctions.ContainsKey($cmd)) { continue }
            foreach ($el in $c.CommandElements) {
                if ($el -is [Management.Automation.Language.CommandParameterAst]) {
                    $script:callSites += @{
                        File     = $rel
                        Line     = $c.Extent.StartLineNumber
                        Command  = $cmd
                        Param    = $el.ParameterName
                        Declared = $libFunctions[$cmd]
                    }
                }
            }
        }
    }
}

BeforeDiscovery {
    $script:countSites = @()
    $root = Split-Path $PSScriptRoot -Parent
    $files = @(Get-ChildItem (Join-Path $root 'lib') -Filter *.ps1) + @(Get-Item (Join-Path $root 'gui/Gui.ps1')) + @(Get-Item (Join-Path $root 'CiscoC9200-OT-Investigation.ps1'))
    foreach ($f in $files) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $hits = $ast.FindAll({
            param($n)
            $n -is [Management.Automation.Language.MemberExpressionAst] -and
            $n.Member.Extent.Text -eq 'Count' -and
            $n.Expression -is [Management.Automation.Language.ParenExpressionAst] -and
            $n.Expression.Pipeline -is [Management.Automation.Language.PipelineAst] -and
            $n.Expression.Pipeline.PipelineElements.Count -gt 1
        }, $true)
        foreach ($h in $hits) {
            $script:countSites += @{ File = $f.Name; Line = $h.Extent.StartLineNumber; Text = $h.Extent.Text }
        }
    }
    if ($script:countSites.Count -eq 0) { $script:countSites = @(@{ File = '(none)'; Line = 0; Text = '' }) }
}

BeforeDiscovery {
    $script:nestSites = @()
    $root = Split-Path $PSScriptRoot -Parent
    $commaReturners = @()
    foreach ($lib in Get-ChildItem (Join-Path $root 'lib') -Filter *.ps1) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($lib.FullName, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $returnsComma = $fn.Body.FindAll({
                param($n)
                $n -is [Management.Automation.Language.ReturnStatementAst] -and
                $n.Pipeline -and $n.Pipeline.Extent.Text.TrimStart().StartsWith(',')
            }, $true)
            if ($returnsComma.Count -gt 0) { $commaReturners += $fn.Name }
        }
    }
    foreach ($rel in 'CiscoC9200-OT-Investigation.ps1', 'gui/Gui.ps1') {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $rel), [ref]$null, [ref]$null)
        foreach ($arr in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.ArrayExpressionAst] }, $true)) {
            $inner = $arr.SubExpression.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)
            foreach ($c in $inner) {
                if ($commaReturners -contains $c.GetCommandName()) {
                    $script:nestSites += @{ File = $rel; Line = $arr.Extent.StartLineNumber; Command = $c.GetCommandName() }
                }
            }
        }
    }
    if ($script:nestSites.Count -eq 0) { $script:nestSites = @(@{ File = '(none)'; Line = 0; Command = '' }) }
}

Describe 'Functions that return ", $array" are not wrapped in @() (would nest the array)' {
    It '<File>:<Line> does not wrap <Command> in @()' -ForEach $script:nestSites {
        $Command | Should -BeNullOrEmpty -Because "$Command returns ', `$array'; @() would nest it as a single element. Assign the result directly."
    }
}

Describe 'Piped results are wrapped in @() before .Count (StrictMode 2.0 safety)' {
    It '<File>:<Line> does not call .Count on an unwrapped pipeline' -ForEach $script:countSites {
        $Text | Should -BeNullOrEmpty -Because "(pipeline).Count throws under StrictMode when the pipeline returns nothing; use @(pipeline).Count"
    }
}

Describe 'Entry point and GUI call library functions with valid parameters' {
    It '<File>:<Line> <Command> -<Param> exists in the function signature' -ForEach $script:callSites {
        $Declared | Should -Contain $Param -Because "$Command does not declare -$Param (simple functions silently swallow unknown named arguments)"
    }
}
