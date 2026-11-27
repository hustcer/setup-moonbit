import assert from 'node:assert/strict'
import { execFileSync, spawn } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'

const downloader = fileURLToPath(new URL('../download.nu', import.meta.url))
const windows = process.platform === 'win32'
const archive = randomBytes(96 * 1024)
const replacement = randomBytes(archive.length)
const firstOffset = 16 * 1024
const secondOffset = 48 * 1024
const etag = '"original"'
const newEtag = '"replacement"'
const digest = (body) => createHash('sha256').update(body).digest('hex')

function full(body = archive, tag = etag, options = {}) {
  return { status: 200, headers: { 'Content-Length': body.length, ETag: tag }, body, ...options }
}

function range(start, end = archive.length - 1, options = {}) {
  return {
    requestRange: `bytes=${start}-`,
    requestEtag: etag,
    status: 206,
    headers: {
      'Content-Range': `bytes ${start}-${end}/${archive.length}`,
      'Content-Length': end - start + 1,
      ETag: etag,
    },
    body: archive.subarray(start, end + 1),
    ...options,
  }
}

function checksum(body = archive) {
  return { status: 200, body: `${digest(body)}  archive.tar.gz\n` }
}

function startDownload(url, destination, cache) {
  const child = spawn('nu', ['--no-config-file', downloader, url, destination, cache], {
    detached: !windows,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const output = []
  child.stdout.on('data', (chunk) => output.push(chunk))
  child.stderr.on('data', (chunk) => output.push(chunk))
  const done = new Promise((resolve, reject) => {
    child.once('error', reject)
    child.once('close', (code, signal) => resolve({ code, signal, output: Buffer.concat(output).toString() }))
  })
  return { child, done }
}

function killDownload(child) {
  if (child.exitCode !== null || child.signalCode !== null) return
  if (windows) {
    execFileSync('taskkill', ['/T', '/F', '/PID', String(child.pid)], { stdio: 'ignore' })
  } else {
    process.kill(-child.pid, 'SIGKILL')
  }
}

async function waitFor(ready) {
  for (let i = 0; i < 200; i += 1) {
    if (await ready()) return
    await delay(25)
  }
  assert.fail('The downloader did not write the expected partial file')
}

test('MoonBit archive downloads', { timeout: 90_000 }, async (t) => {
  const work = await mkdtemp(join(tmpdir(), 'setup moonbit [downloads] '))
  const cache = join(work, 'cache')
  const steps = new Map()
  const errors = []
  const children = []
  const server = createServer((request, response) => {
    try {
      const step = steps.get(request.url)?.shift()
      assert.ok(step, `Unexpected request for ${request.url}`)
      assert.equal(request.method, 'GET')
      assert.equal(request.headers.range, step.requestRange)
      assert.equal(request.headers['if-range'], step.requestEtag)
      if (!request.url.endsWith('.sha256')) assert.equal(request.headers['accept-encoding'], 'identity')
      if (step.closeDelimited) response.useChunkedEncodingByDefault = false
      response.writeHead(step.status, step.headers ?? {})
      if (step.cut || step.hold) {
        response.flushHeaders()
        response.write(step.body.subarray(0, step.cut ?? firstOffset))
        step.onHold?.(response)
        if (!step.hold) setTimeout(() => response.destroy(), 75)
      } else {
        response.end(step.body)
      }
    } catch (error) {
      errors.push(error)
      response.writeHead(500).end()
    }
  })
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })
  t.after(async () => {
    for (const child of children) killDownload(child)
    server.closeAllConnections()
    await new Promise((resolve) => server.close(resolve))
    await rm(work, { recursive: true, force: true })
  })
  const base = `http://127.0.0.1:${server.address().port}`

  function scenario(name, transfers, checksums = [checksum()]) {
    const path = `/${name}`
    const url = `${base}${path}`
    const key = digest(url)
    steps.set(path, transfers)
    steps.set(`${path}.sha256`, checksums)
    return {
      part: join(cache, `${key}.part`),
      state: join(cache, `${key}.json`),
      lock: join(cache, `${key}.lock`),
      start(suffix = '') {
        const destination = join(work, `${name}${suffix}.tar.gz`)
        const run = startDownload(url, destination, cache)
        children.push(run.child)
        return { ...run, destination }
      },
    }
  }

  async function succeeded(run, expected = archive) {
    const result = await run.done
    assert.equal(result.code, 0, result.output)
    assert.equal(digest(await readFile(run.destination)), digest(expected), result.output)
  }

  async function interrupted(run, part, offset) {
    const result = await run.done
    assert.notEqual(result.code, 0, result.output)
    await assert.rejects(stat(run.destination), { code: 'ENOENT' })
    const partial = await readFile(part)
    assert.equal(partial.length, offset, result.output)
    assert.equal(digest(partial), digest(archive.subarray(0, offset)), result.output)
  }

  await t.test('resumes after two consecutive interrupted transfers', async () => {
    const run = scenario('resume', [
      full(archive, etag, { cut: firstOffset }),
      range(firstOffset, archive.length - 1, { cut: secondOffset - firstOffset }),
      range(secondOffset),
    ])
    await interrupted(run.start(), run.part, firstOffset)
    await interrupted(run.start(), run.part, secondOffset)
    await succeeded(run.start())
    await assert.rejects(stat(run.part), { code: 'ENOENT' })
  })

  await t.test('gets the total size from Content-Range after a chunked transfer breaks', async () => {
    const run = scenario('chunked', [
      full(archive, etag, { headers: { ETag: etag }, cut: firstOffset }),
      range(firstOffset),
    ], [{ status: 404 }])
    await interrupted(run.start(), run.part, firstOffset)
    await succeeded(run.start())
  })

  await t.test('does not publish an EOF-delimited body without length or checksum', async () => {
    const run = scenario('unframed', [
      full(archive.subarray(0, firstOffset), etag, { headers: { ETag: etag, Connection: 'close' }, closeDelimited: true }),
      range(firstOffset),
    ], [{ status: 404 }, { status: 404 }])
    await interrupted(run.start(), run.part, firstOffset)
    await succeeded(run.start())
  })

  await t.test('recovers when the saved metadata has the wrong shape', async () => {
    const run = scenario('bad-metadata', [full(archive, etag, { cut: firstOffset }), full()])
    await interrupted(run.start(), run.part, firstOffset)
    await writeFile(run.state, '42')
    await succeeded(run.start())
  })

  await t.test('uses the full response when the ETag changes', async () => {
    const run = scenario('replaced', [
      full(archive, etag, { cut: firstOffset }),
      full(replacement, newEtag, { requestRange: `bytes=${firstOffset}-`, requestEtag: etag }),
    ], [checksum(replacement)])
    await interrupted(run.start(), run.part, firstOffset)
    await succeeded(run.start(), replacement)
  })

  await t.test('does not reuse the ETag of a different redirect target', async () => {
    const run = scenario('redirect', [
      { status: 302, headers: { Location: '/original-target' } },
      { status: 302, headers: { Location: '/replacement-target' }, requestRange: `bytes=${firstOffset}-`, requestEtag: etag },
      { status: 302, headers: { Location: '/replacement-target' } },
    ], [checksum(replacement)])
    steps.set('/original-target', [full(archive, etag, { cut: firstOffset })])
    steps.set('/replacement-target', [range(firstOffset, archive.length - 1, { body: replacement.subarray(firstOffset) }), full(replacement)])
    await interrupted(run.start(), run.part, firstOffset)
    await succeeded(run.start(), replacement)
  })

  await t.test('restarts after 416, a wrong range, or a wrong ETag', async () => {
    const request = { requestRange: `bytes=${firstOffset}-`, requestEtag: etag }
    const badResponses = [
      { ...request, status: 416, headers: { 'Content-Range': `bytes */${firstOffset}` } },
      range(firstOffset + 1, archive.length - 1, request),
      { ...range(firstOffset), headers: { ...range(firstOffset).headers, ETag: newEtag } },
    ]
    for (const [index, badResponse] of badResponses.entries()) {
      const run = scenario(`invalid-range-${index}`, [full(archive, etag, { cut: firstOffset }), badResponse, full()])
      await interrupted(run.start(), run.part, firstOffset)
      await succeeded(run.start())
    }
  })

  await t.test('starts afresh if the partial response had no strong ETag', async () => {
    const run = scenario('weak-validator', [full(archive, `W/${etag}`, { cut: firstOffset }), full()], [{ status: 403 }])
    await interrupted(run.start(), run.part, firstOffset)
    await succeeded(run.start())
  })

  await t.test('revalidates a complete partial file after a checksum request fails', async () => {
    const run = scenario('complete-part', [full(), range(0, 0, { requestRange: 'bytes=0-0' })], [
      { status: 503 },
      checksum(),
    ])
    await interrupted(run.start(), run.part, archive.length)
    await succeeded(run.start())
  })

  await t.test('rejects a checksum mismatch without publishing the archive', async () => {
    const run = scenario('checksum-mismatch', [full(), full()], [checksum(replacement), checksum()])
    const failed = run.start()
    const result = await failed.done
    assert.notEqual(result.code, 0, result.output)
    assert.match(result.output, /SHA-256 mismatch/)
    await assert.rejects(stat(failed.destination), { code: 'ENOENT' })
    await assert.rejects(stat(run.part), { code: 'ENOENT' })
    await succeeded(run.start())
  })

  await t.test('waits for the lock and resumes streaming bytes after a hard interruption', async () => {
    const run = scenario('concurrent', [full(archive, etag, { hold: true }), range(firstOffset)])
    const first = run.start('-first')
    await waitFor(async () => (await stat(run.part).catch(() => null))?.size === firstOffset)
    const second = run.start('-second')
    await delay(300)
    assert.equal(steps.get('/concurrent').length, 1, 'A concurrent writer sent a request while the lock was held')
    killDownload(first.child)
    assert.notEqual((await first.done).code, 0)
    await succeeded(second)
  })

  if (windows) {
    await t.test('the writer keeps the lock after its PowerShell parent is killed', async () => {
      let held
      const run = scenario('orphan-writer', [
        full(archive, etag, { hold: true, onHold: (response) => { held = response } }),
        full(),
      ], [checksum(), checksum()])
      const first = run.start('-first')
      await waitFor(async () => (await stat(run.part).catch(() => null))?.size === firstOffset)
      const lockPid = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
        '(Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $env:MOONBIT_TEST_PARENT_PID) | Where-Object Name -eq powershell.exe).ProcessId',
      ], { env: { ...process.env, MOONBIT_TEST_PARENT_PID: String(first.child.pid) }, encoding: 'utf8' }).trim()
      assert.match(lockPid, /^\d+$/)
      execFileSync('taskkill', ['/F', '/PID', lockPid], { stdio: 'ignore' })
      const lockError = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
        "try { [IO.File]::Open($env:MOONBIT_TEST_LOCK, 'Open', 'ReadWrite', 'None').Dispose() } catch [IO.IOException] { $_.Exception.GetBaseException().HResult -band 0xffff }",
      ], { env: { ...process.env, MOONBIT_TEST_LOCK: run.lock }, encoding: 'utf8' }).trim()
      assert.equal(lockError, '32', 'The orphaned writer lost its cache lock')
      const second = run.start('-second')
      held.end(archive.subarray(firstOffset))
      await first.done
      await succeeded(second)
      assert.equal(digest(await readFile(first.destination)), digest(archive))
    })
  }

  assert.deepEqual(errors, [])
  assert.ok([...steps.values()].every((requests) => requests.length === 0), 'The fixture did not observe all requests')
  assert.ok((await readdir(cache)).every((name) => name.endsWith('.lock')), 'A completed download left partial state')
})
