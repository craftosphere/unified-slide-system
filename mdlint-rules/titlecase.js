// Custom markdownlint rule: title-case headings (HTML-aware)
//
// Zero external dependencies. Implements AP-style title case internally
// with one-way flagging: only flags words the author lowercased that
// should be uppercase — never flags intentional capitalization of
// ambiguous words (phrasal-verb particles like "Up", "Over", etc.).
//
// Usage in .markdownlint-cli2.jsonc:
//   "customRules": ["./rules/titlecase.js"]

"use strict";

// Words that stay lowercase unless first or last in the heading.
// Based on AP style: articles, coordinating conjunctions, and
// short prepositions (≤ 4 letters) plus common longer ones.
var SMALL_WORDS = [
  // articles
  "a", "an", "the",
  // coordinating conjunctions
  "and", "but", "or", "nor", "for", "yet", "so",
  // prepositions
  "as", "at", "by", "from", "in", "into", "of", "off",
  "on", "onto", "out", "over", "per", "to", "up", "upon",
  "via", "with",
];

function toTitleCase(text) {
  var words = text.split(/\s+/);
  return words
    .map(function (word, i) {
      if (!word) return word;
      var isFirst = i === 0;
      var isLast = i === words.length - 1;

      // Always capitalise first and last word
      if (isFirst || isLast) {
        return word.charAt(0).toUpperCase() + word.slice(1);
      }

      // Keep small words lowercase (case-insensitive check)
      if (SMALL_WORDS.indexOf(word.toLowerCase()) !== -1) {
        return word.toLowerCase();
      }

      // Capitalise everything else
      return word.charAt(0).toUpperCase() + word.slice(1);
    })
    .join(" ");
}

function stripHtml(text) {
  return text
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/&#\d+;/g, "")
    .trim();
}

module.exports = {
  names: ["titlecase", "heading-titlecase"],
  description: "Headings should use title case (HTML-aware)",
  tags: ["headings"],
  parser: "markdownit",
  function: function rule(params, onError) {
    params.parsers.markdownit.tokens
      .filter(function (token) {
        return token.type === "heading_open";
      })
      .forEach(function (token) {
        var lineNumber = token.lineNumber;
        var line = params.lines[lineNumber - 1] || "";

        // Strip markdown heading prefix, then HTML
        var headingText = line.replace(/^#+\s*/, "");
        var plainText = stripHtml(headingText);

        if (!plainText) return;

        var expected = toTitleCase(plainText);
        var actualWords = plainText.split(/\s+/);
        var expectedWords = expected.split(/\s+/);

        if (actualWords.length !== expectedWords.length) return;

        // One-way flagging: only flag words the author wrote lowercase
        // that should be uppercase. If the author capitalised a word
        // the rule would lowercase (e.g. "Up" as a phrasal-verb
        // particle), that is accepted — never flag overcapitalisation.
        var violations = [];
        actualWords.forEach(function (actual, i) {
          var exp = expectedWords[i];
          if (!actual || !exp) return;

          // Author wrote lowercase, rule says uppercase → violation
          if (
            actual[0] !== actual[0].toUpperCase() &&
            exp[0] === exp[0].toUpperCase()
          ) {
            violations.push(actual + " → " + exp);
          }
        });

        if (violations.length > 0) {
          onError({
            lineNumber: lineNumber,
            detail: 'Expected: "' + expected + '"',
            context: plainText,
          });
        }
      });
  },
};
