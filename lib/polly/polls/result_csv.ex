NimbleCSV.define(Polly.Polls.ResultCSV,
  separator: ",",
  escape: "\"",
  line_separator: "\r\n",
  escape_formula: %{["@", "+", "-", "=", "\t", "\r"] => "'"}
)
