// Copyright 2026 Leo Cheng
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// The self-verifying conformance harness. `run_conformance` drives every
/// `Event` variant, every `Scope` field, and every ordering rule through the
/// synchronous cores, then reports how many checks passed and names any that
/// failed. A server or framework built on the seam can call it to self-verify
/// its wiring.
///
///     moon run src/examples/12-conformance
#coverage.skip
fn main {
  let report = @moonasgi.run_conformance()
  println("conformance: \{report.passed}/\{report.total} checks passed")
  println("ok = \{report.ok()}")
  if report.ok() {
    println("no failures")
  } else {
    println("failures:")
    for name in report.failures {
      println("  " + name)
    }
  }
}
