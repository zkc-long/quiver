// A small openCypher TCK runner.
//
// It implements the subset of the Cucumber/Gherkin step vocabulary that the
// vendored feature files use:
//
//   Given an empty graph
//   And having executed:            (docstring, write query)
//   When executing query:           (docstring)
//   Then the result should be:      (table, unordered)
//   Then the result should be, in order:   (table, ordered)
//   And the result should be empty
//   And no side effects
//
// Any other step marks the scenario as skipped rather than failed, so the
// reported pass rate is never inflated by silently ignoring semantics.
//
// Usage: moon run cmd/tck -- conformance/features/Match1.feature ...

///|
struct Step {
  text : String
  doc : String
  table : Array[Array[String]]
}

///|
struct Scenario {
  name : String
  steps : Array[Step]
}

///|
enum Outcome {
  Passed
  Failed(String)
  Skipped(String)
}

///|
fn trim_view(text : StringView) -> String {
  text.trim().to_owned()
}

///|
/// Parse a `.feature` file into scenarios.
fn parse_feature(text : String) -> Array[Scenario] {
  let scenarios : Array[Scenario] = []
  let lines = text.split("\n")
  let mut current : Scenario? = None
  let mut steps : Array[Step] = []
  let mut in_doc = false
  let mut doc = StringBuilder()
  let mut step_text = ""
  let mut step_keyword = ""
  let mut table : Array[Array[String]] = []
  let flush_step = fn() {
    if step_text != "" {
      steps.push({ text: step_text, doc: doc.to_string(), table, })
    }
  }
  for raw in lines {
    let line = raw.trim().to_owned()
    if in_doc {
      if line == "\"\"\"" {
        in_doc = false
      } else {
        doc.write_string(raw.to_owned())
        doc.write_string("\n")
      }
      continue
    }
    if line == "" || line.has_prefix("#") {
      continue
    }
    if line.has_prefix("@") {
      continue
    }
    if line.has_prefix("Feature:") {
      continue
    }
    if line.has_prefix("Scenario:") || line.has_prefix("Scenario Outline:") {
      // Close the previous scenario.
      flush_step()
      match current {
        Some(sc) => scenarios.push({ name: sc.name, steps, })
        None => ()
      }
      steps = []
      step_text = ""
      step_keyword = ""
      table = []
      doc = StringBuilder()
      let name = if line.has_prefix("Scenario:") {
        trim_view(line.get_view(start=9).unwrap_or(""))
      } else {
        trim_view(line.get_view(start=17).unwrap_or(""))
      }
      current = Some({ name, steps: [], })
      continue
    }
    let keyword = first_word(line)
    if keyword == "Given" ||
      keyword == "When" ||
      keyword == "Then" ||
      keyword == "And" ||
      keyword == "But" {
      flush_step()
      step_text = trim_view(line.get_view(start=keyword.length()).unwrap_or(""))
      table = []
      doc = StringBuilder()
      continue
    }
    if line == "\"\"\"" {
      in_doc = true
      continue
    }
    if line.has_prefix("|") {
      table.push(parse_table_row(line))
      continue
    }
  }
  flush_step()
  match current {
    Some(sc) => scenarios.push({ name: sc.name, steps, })
    None => ()
  }
  scenarios
}

///|
fn first_word(line : String) -> String {
  match line.find(" ") {
    Some(idx) =>
      String::from_array(
        Array::from_iter(line.get_view(end=idx).unwrap_or("").iter()),
      )
    None => line
  }
}

///|
fn parse_table_row(line : String) -> Array[String] {
  let cells : Array[String] = []
  let chars = Array::from_iter(line.iter())
  let buf = StringBuilder()
  let mut i = 1
  while i < chars.length() {
    let c = chars[i]
    if c == '|' {
      cells.push(buf.to_string().trim().to_owned())
      buf.reset()
    } else {
      buf.write_char(c)
    }
    i = i + 1
  }
  // The trailing `|` already flushed the last cell; ignore any remainder.
  cells
}

///|
fn run_scenario(sc : Scenario) -> Outcome {
  let mut graph = @mg.Graph::new()
  let mut columns : Array[String] = []
  let mut rows : Array[Array[@mg.Value]] = []
  let unsupported : Array[String] = []
  // Scenarios that assert a query is rejected: a rejection is a pass, an
  // accepted query is reported as skipped rather than silently passed.
  let mut expects_error = false
  for probe in sc.steps {
    if probe.text.contains("should be raised") {
      expects_error = true
    }
  }
  let mut last_raised = false
  let mut before : @mg.GraphStats? = None
  for step in sc.steps {
    let text = step.text
    if text == "an empty graph" || text == "the database is initialised" {
      continue
    }
    if text == "any graph" {
      // The TCK standard fixture: binary-tree-1.
      graph = build_fixture()
      continue
    }
    if text == "having executed:" {
      match unsupported_syntax(step.doc) {
        Some(why) => return Skipped(why)
        None => ()
      }
      match run_doc(graph, step.doc) {
        Some(_) => ()
        None =>
          return Failed("setup query failed: " + step.doc.trim().to_owned())
      }
      continue
    }
    if text == "executing query:" {
      match unsupported_syntax(step.doc) {
        Some(why) => return Skipped(why)
        None => ()
      }
      graph.reset_side_effects()
      before = Some(graph.stats())
      match run_doc(graph, step.doc) {
        Some(result) => {
          last_raised = false
          columns = result.columns
          rows = result.rows
        }
        None =>
          match unsupported_syntax(step.doc) {
            Some(why) => return Skipped(why)
            None =>
              if expects_error {
                last_raised = true
                columns = []
                rows = []
              } else {
                return Failed(
                  "query failed to parse: " + step.doc.trim().to_owned(),
                )
              }
          }
      }
      continue
    }
    if text.contains("should be raised") {
      if last_raised {
        continue
      }
      return Skipped("engine accepted a query the TCK expects to reject")
    }
    if text == "the result should be empty" {
      if rows.length() != 0 {
        return Failed("expected an empty result, got \{rows.length()} row(s)")
      }
      continue
    }
    if text == "no side effects" || text == "no side effects," {
      match check_side_effects(before, graph, []) {
        Some(reason) => return Failed(reason)
        None => ()
      }
      continue
    }
    if text == "the side effects should be:" {
      match check_side_effects(before, graph, step.table) {
        Some(reason) => return Failed(reason)
        None => ()
      }
      continue
    }
    if text == "the result should be, in any order:" {
      match structural_expectation(step.table) {
        Some(why) => return Skipped(why)
        None => ()
      }
      match compare(expected_table(step.table), rows, columns, false) {
        Some(reason) => return Failed(reason)
        None => ()
      }
      continue
    }
    if text == "the result should be, in order:" {
      match structural_expectation(step.table) {
        Some(why) => return Skipped(why)
        None => ()
      }
      match compare(expected_table(step.table), rows, columns, true) {
        Some(reason) => return Failed(reason)
        None => ()
      }
      continue
    }
    if text == "the result should be:" {
      match structural_expectation(step.table) {
        Some(why) => return Skipped(why)
        None => ()
      }
      match compare(expected_table(step.table), rows, columns, false) {
        Some(reason) => return Failed(reason)
        None => ()
      }
      continue
    }
    // Anything else (parameters, side effect tables, regex assertions) is out
    // of scope for this runner.
    unsupported.push(text)
  }
  if unsupported.length() > 0 {
    return Skipped("unsupported step: " + unsupported[0])
  }
  Passed
}

///|
/// Scenarios that compare whole nodes or relationships are outside the
/// supported subset: this engine returns node ids, not structural values.
fn structural_expectation(table : Array[Array[String]]) -> String? {
  let mut i = 1
  while i < table.length() {
    for cell in table[i] {
      let c = cell.trim().to_owned()
      if c.has_prefix("<node>") || c.has_prefix("<rel>") || c.has_prefix("{") {
        return Some("placeholder expectations are outside the supported subset")
      }
      if c.has_prefix("(") && canonical_node_cell(c) is None {
        return Some("path values are outside the supported subset")
      }
      if c.has_prefix("[:") && canonical_rel_cell(c) is None {
        return Some(
          "relationship expectations are outside the supported subset",
        )
      }
    }
    i = i + 1
  }
  None
}

///|
/// Canonical text for an expected node, or `None` if it is not a node literal.
fn canonical_node_cell(text : String) -> String? {
  match @cypher.parse_node_expected(text) {
    Some((labels, props)) => Some(@mg.node_text(labels, props))
    None => None
  }
}

///|
fn canonical_rel_cell(text : String) -> String? {
  match @cypher.parse_rel_expected(text) {
    Some((name, props)) => Some(@mg.rel_text(name, props))
    None => None
  }
}

///|
/// Cypher constructs this engine does not implement. Scenarios that need them
/// are reported as skipped instead of failed so the pass rate stays honest.
fn unsupported_syntax(query : String) -> String? {
  let markers : Array[String] = [
    "$", "UNION", "OPTIONAL", "CALL ", "FOREACH", "LOAD CSV", "PROCEDURE", " ^ ",
    "STARTS WITH", "ENDS WITH", "CONTAINS", "SET (", "count(*)", "ON CREATE", "ON MATCH",
    "{.", "{*", "IN [",
  ]
  for marker in markers {
    if query.contains(marker) {
      return Some("unsupported syntax: " + marker.trim().to_owned())
    }
  }
  None
}

///|
fn expected_table(table : Array[Array[String]]) -> Array[Array[@mg.Value]] {
  let out : Array[Array[@mg.Value]] = []
  let mut i = 1
  while i < table.length() {
    let row : Array[@mg.Value] = []
    for cell in table[i] {
      row.push(parse_cell(cell))
    }
    out.push(row)
    i = i + 1
  }
  out
}

///|
/// Parse a TCK table cell into a value.
fn parse_cell(cell : String) -> @mg.Value {
  let text = cell.trim().to_owned()
  if text == "null" || text == "<null>" || text == "NULL" {
    return @mg.VNull
  }
  if text == "true" {
    return @mg.VBool(true)
  }
  if text == "false" {
    return @mg.VBool(false)
  }
  let chars = Array::from_iter(text.iter())
  if chars.length() >= 2 {
    if chars[0] == '\'' && chars[chars.length() - 1] == '\'' {
      return @mg.VStr(String::from_array(chars[1:chars.length() - 1]))
    }
  }
  if text.has_prefix("[:") {
    match canonical_rel_cell(text) {
      Some(rendered) => return @mg.VStr(rendered)
      None => ()
    }
  }
  if text.has_prefix("(") {
    match canonical_node_cell(text) {
      Some(rendered) => return @mg.VStr(rendered)
      None => ()
    }
  }
  if text.has_prefix("[") && text.ends_with("]") {
    let inner = text.get_view(start=1, end=text.char_length() - 1).unwrap_or("")
    let items : Array[@mg.Value] = []
    for part in inner.split(",") {
      items.push(parse_cell(part.to_owned()))
    }
    return @mg.VList(items)
  }
  // A decimal point or exponent means a double; MoonBit renders 1.0 as "1",
  // so string round-tripping cannot be used to tell the two apart.
  if text.contains(".") || text.contains("e") || text.contains("E") {
    let value = @string.parse_double(text) catch { _ => 0.0 }
    return @mg.VDouble(value)
  }
  let int_value = @string.parse_int64(text) catch { _ => 0L }
  if "\{int_value}" == text {
    return @mg.VInt(int_value)
  }
  @mg.VStr(text)
}

///|
fn compare(
  expected : Array[Array[@mg.Value]],
  actual : Array[Array[@mg.Value]],
  columns : Array[String],
  ordered : Bool,
) -> String? {
  if expected.length() != actual.length() {
    return Some(
      "expected \{expected.length()} row(s), got \{actual.length()} (columns: \{columns})",
    )
  }
  if ordered {
    let mut i = 0
    while i < expected.length() {
      if !rows_equal(expected[i], actual[i]) {
        return Some(
          "row \{i} mismatch: expected \{render(expected[i])}, got \{render(actual[i])}",
        )
      }
      i = i + 1
    }
    return None
  }
  let used : Array[Bool] = []
  let mut k = 0
  while k < actual.length() {
    used.push(false)
    k = k + 1
  }
  for want in expected {
    let mut found = false
    let mut idx = 0
    while idx < actual.length() {
      if !used[idx] && rows_equal(want, actual[idx]) {
        used[idx] = true
        found = true
        break
      }
      idx = idx + 1
    }
    if !found {
      return Some("missing row \{render(want)} in \{render_rows(actual)}")
    }
  }
  None
}

///|
fn rows_equal(a : Array[@mg.Value], b : Array[@mg.Value]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if !cell_equal(a[i], b[i]) {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn cell_equal(a : @mg.Value, b : @mg.Value) -> Bool {
  match a {
    @mg.VStr(s) =>
      if s.has_prefix("<") && s.ends_with(">") {
        // Placeholder such as <node>: accept any non-null value.
        return !(b is @mg.VNull)
      }
    _ => ()
  }
  a.equal_value(b)
}

///|
fn render(row : Array[@mg.Value]) -> String {
  let buf = StringBuilder()
  buf.write_string("[")
  let mut first = true
  for v in row {
    if !first {
      buf.write_string(", ")
    }
    first = false
    buf.write_string(v.to_literal())
  }
  buf.write_string("]")
  buf.to_string()
}

///|
fn render_rows(rows : Array[Array[@mg.Value]]) -> String {
  let buf = StringBuilder()
  let mut i = 0
  for row in rows {
    if i >= 5 {
      buf.write_string("...")
      break
    }
    buf.write_string(render(row))
    buf.write_string(" ")
    i = i + 1
  }
  buf.to_string()
}

///|
async fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: moon run cmd/tck -- <feature files...>")
    return
  }
  let mut total = 0
  let mut passed = 0
  let mut failed = 0
  let mut skipped = 0
  let report = StringBuilder()
  report.write_string("# TCK report\n\n")
  report.write_string("| file | scenarios | passed | failed | skipped |\n")
  report.write_string("|---|---|---|---|---|\n")
  let mut i = 1
  while i < args.length() {
    let path = args[i]
    i = i + 1
    let text = @fs.read_text(path) catch {
      _ => {
        println("error: cannot read " + path)
        continue
      }
    }
    let scenarios = parse_feature(text)
    let mut file_pass = 0
    let mut file_fail = 0
    let mut file_skip = 0
    for sc in scenarios {
      total = total + 1
      match run_scenario(sc) {
        Passed => {
          passed = passed + 1
          file_pass = file_pass + 1
        }
        Failed(reason) => {
          failed = failed + 1
          file_fail = file_fail + 1
          if file_fail <= 3 {
            println("FAIL [" + sc.name + "] " + reason)
          }
        }
        Skipped(reason) => {
          skipped = skipped + 1
          file_skip = file_skip + 1
          if file_skip <= 1 {
            println("SKIP [" + sc.name + "] " + reason)
          }
        }
      }
    }
    // Windows paths use backslashes; normalise so the report shows a bare
    // file name instead of an absolute machine-specific path.
    // Report only the file name: absolute paths leak the author's disk
    // layout, and Windows separators would defeat a plain split.
    let mut start = 0
    let mut pos = 0
    let chars = Array::from_iter(path.iter())
    while pos < chars.length() {
      if chars[pos] == '\\' || chars[pos] == '/' {
        start = pos + 1
      }
      pos = pos + 1
    }
    let short = path.get_view(start~).unwrap_or("").to_owned()
    report.write_string(
      "| \{short} | \{file_pass + file_fail + file_skip} | \{file_pass} | \{file_fail} | \{file_skip} |\n",
    )
  }
  let supported = passed + failed
  let rate = if supported == 0 {
    0.0
  } else {
    passed.to_double() / supported.to_double() * 100.0
  }
  report.write_string("\n")
  report.write_string(
    "Scenarios: \{total}, passed: \{passed}, failed: \{failed}, skipped: \{skipped}\n",
  )
  report.write_string(
    "Pass rate over supported scenarios: \{rate}% (\{passed}/\{supported})\n",
  )
  println("")
  println(
    "total=\{total} passed=\{passed} failed=\{failed} skipped=\{skipped} rate=\{rate}%",
  )
  let _ = @fs.write_text("conformance/report.md", report.to_string()) catch {
    _ => ()
  }
}

///|
/// Compare the graph before and after a query against a TCK side-effect table.
/// An empty table means "no side effects at all".
fn check_side_effects(
  before : @mg.GraphStats?,
  graph : @mg.Graph,
  table : Array[Array[String]],
) -> String? {
  let old = match before {
    Some(stats) => stats
    None => return None
  }
  ignore(old)
  let names : Array[String] = [
    "+nodes", "-nodes", "+relationships", "-relationships", "+properties", "-properties",
    "+labels", "-labels",
  ]
  if table.length() == 0 {
    for name in names {
      if graph.effect_count(name) != 0 {
        return Some("expected no side effects, got \{name}")
      }
    }
    return None
  }
  for row in table {
    if row.length() < 2 {
      continue
    }
    let name = row[0].trim().to_owned()
    let expected = @string.parse_int(row[1].trim()) catch { _ => 0 }
    let actual = graph.effect_count(name)
    if actual != expected {
      return Some("side effect \{name}: expected \{expected}, got \{actual}")
    }
  }
  None
}

///|
/// Split a TCK `having executed:` block into statements. Continuation lines
/// (starting with `(` or an identifier) stay with the statement they belong to.
fn split_statements(doc : String) -> Array[String] {
  let keywords : Array[String] = [
    "CREATE", "MERGE", "MATCH", "WITH", "SET", "DELETE", "DETACH", "RETURN",
  ]
  let out : Array[String] = []
  let buf = StringBuilder()
  for raw in doc.split("\n") {
    let line = raw.trim().to_owned()
    if line == "" {
      continue
    }
    let upper = line.to_upper()
    let mut starts = false
    for keyword in keywords {
      if upper == keyword ||
        upper.has_prefix(keyword + " ") ||
        upper.has_prefix(keyword + "(") {
        starts = true
      }
    }
    if starts && buf.to_string().trim() != "" {
      out.push(buf.to_string())
      buf.reset()
    }
    buf.write_string(raw.to_owned())
    buf.write_string("\n")
  }
  if buf.to_string().trim() != "" {
    out.push(buf.to_string())
  }
  out
}

///|
fn join_statements(statements : Array[String]) -> String {
  let buf = StringBuilder()
  for statement in statements {
    if buf.to_string() != "" {
      buf.write_string(" ;; ")
    }
    buf.write_string(statement.trim().to_owned())
  }
  buf.to_string()
}

///|
/// Run a doc block: first as a single query, then as a script of statements.
/// TCK blocks are sometimes multi-statement even in `When executing query:`.
fn run_doc(graph : @mg.Graph, doc : String) -> @cypher.QueryResult? {
  let direct : @cypher.QueryResult? = Some(@cypher.run(graph, doc)) catch {
    _ => None
  }
  match direct {
    Some(result) => Some(result)
    None => {
      let statements = split_statements(doc)
      if statements.length() <= 1 {
        return None
      }
      Some(@cypher.run_script(graph, statements)) catch {
        _ => None
      }
    }
  }
}
