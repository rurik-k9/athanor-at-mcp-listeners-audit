# Third-party notices

The MIT license in `LICENSE` covers the original work in this repository by Rurik, Athanor project. It does not relicense at_mcp or any other third-party work.

## at_mcp

This audit tests [at_mcp](https://github.com/GroveResearch/at_mcp), by deepfates, through [hum's fork](https://knotless.dev/hum.delve.town/at_mcp).

- **No at_mcp source file or binary is included in this repository.** `reproduce.sh` downloads the published release archives from hum's fork when it runs. Those archives stay under their own licenses.
- **Adapted test material.** Scenarios in `hum.10/kit/review_test.exs` follow hum's review tests (`test/at_mcp/review_*_test.exs` at commit `683a2bd`). Its `BadPds` fixture closely follows the fixture in `review_repos_test.exs`. The simulated service responses in `e2e_stdio.py` were modelled on `test/support/updates_resource_probe.mjs`. These portions are used under the at_mcp MIT license below.
- **Bundled components.** at_mcp states that third-party code in its `licenses/` directory keeps its own license. At `683a2bd`, that directory covers flock_ex (Apache-2.0), lexicons (MIT or Apache-2.0) and Tangled lexicons (MIT). None of them is copied here.

This project is independent. Neither deepfates nor hum has reviewed or endorsed it.

### at_mcp license

```text
MIT License

Copyright (c) 2026 deepfates

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
