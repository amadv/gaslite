// Returns the startup banner as an array of typed line objects
export default function getBannerLines() {
  return [
    { text: "", type: "stdout" },
    { text: "  gaslite v0.1.0", type: "info" },
    { text: "  Interactive CLI for gaslite", type: "stdout" },
    { text: '  Type "help" for available commands, "exit" to quit.', type: "stdout" },
    { text: "", type: "stdout" },
  ];
}
