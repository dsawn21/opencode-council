#Requires -Version 5.1
<#
    Минимальный JSON-сериализатор: 2 пробела отступа, без сюрпризов
    Windows PowerShell 5.1 (ConvertTo-Json там даёт 4 пробела,
    двойной пробел после двоеточия и \uXXXX вместо не-ASCII).
#>

function ConvertTo-JsonText {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,
        [int]$Level = 0
    )

    $pad    = "  " * $Level
    $padIn  = "  " * ($Level + 1)

    if ($null -eq $InputObject) { return "null" }

    if ($InputObject -is [bool])       { return $(if ($InputObject) { "true" } else { "false" }) }
    if ($InputObject -is [string])     { return (ConvertTo-JsonString $InputObject) }
    if ($InputObject -is [ValueType])  {
        return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $InputObject)
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = @($InputObject)
        if ($items.Count -eq 0) { return "[]" }
        $parts = foreach ($i in $items) { $padIn + (ConvertTo-JsonText -InputObject $i -Level ($Level + 1)) }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }

    $props = @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -in @("NoteProperty", "Property") })
    if ($props.Count -eq 0) { return "{}" }
    $parts = foreach ($p in $props) {
        $padIn + (ConvertTo-JsonString $p.Name) + ": " + (ConvertTo-JsonText -InputObject $p.Value -Level ($Level + 1))
    }
    return "{`n" + ($parts -join ",`n") + "`n$pad}"
}

function ConvertTo-JsonString {
    param([string]$Text)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '"'      { [void]$sb.Append('\"');  continue }
            '\'      { [void]$sb.Append('\\');  continue }
            "`b"     { [void]$sb.Append('\b');  continue }
            "`f"     { [void]$sb.Append('\f');  continue }
            "`n"     { [void]$sb.Append('\n');  continue }
            "`r"     { [void]$sb.Append('\r');  continue }
            "`t"     { [void]$sb.Append('\t');  continue }
            default  {
                if ([int]$ch -lt 0x20) {
                    [void]$sb.Append(('\u{0:x4}' -f [int]$ch))
                }
                else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}
