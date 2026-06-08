import { useState, useEffect, useCallback } from 'react'

// ─── Contract config ──────────────────────────────────────────────────────────
const CONFIG = {
  rpc:          'https://sepolia.unichain.org',
  chainId:      1301,
  brook:        '0xef91EAf413170cAD2f65B3f05E969759df0AA744',
  poolManager:  '0x00B036B58a818B1BC34d502D3fE730Db729e62AC',
  token0:       '0x53C1CDcec62406aD504016344678A3f904696d75',
  token1:       '0xc23376C87B59b4B1FA07CA3A4AD82305845C7126',
  poolId:       '0x0965c7c46f8c0623744ed8273683ce536ef70657a1fcb853ac6c9a6216e0570b',
  epochLength:  7 * 24 * 60 * 60, // 7 days in seconds
  explorer:     'https://unichain-sepolia.blockscout.com',
}

// ─── ABI fragments ────────────────────────────────────────────────────────────
const BROOK_ABI = [
  'function getEpochState(bytes32 poolId) view returns (uint128 buffer, uint128 prevBuffer, uint64 totalScore, uint64 lastUpdateTime, int24 currentTick, int128 lastSkimAmount)',
  'function getPoolConfig(bytes32 poolId) view returns (uint64 epochLength, uint64 startTime, uint16 smoothingFee, uint16 inRangeMultiplier)',
  'function isInitialized(bytes32 poolId) view returns (bool)',
  'function claim(bytes32 poolId, bytes32 positionKey, address recipient)',
  'function computePositionKey(address sender, int24 tickLower, int24 tickUpper, bytes32 salt) view returns (bytes32)',
  'function getLastClaimTime(bytes32 poolId, bytes32 positionKey) view returns (uint64)',
]

// ─── RPC helpers ──────────────────────────────────────────────────────────────
async function rpcCall(method, params) {
  const res = await fetch(CONFIG.rpc, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  const data = await res.json()
  if (data.error) throw new Error(data.error.message)
  return data.result
}

function encodeCall(sig, ...args) {
  // Minimal ABI encoder for view calls we need
  const sighash = keccak256Sig(sig)
  let encoded = sighash
  for (const arg of args) {
    if (typeof arg === 'string' && arg.startsWith('0x')) {
      encoded += arg.slice(2).padStart(64, '0')
    } else if (typeof arg === 'number' || typeof arg === 'bigint') {
      encoded += BigInt(arg).toString(16).padStart(64, '0')
    }
  }
  return encoded
}

// Simple keccak-like via browser — we use known sighashes instead
const SIGHASHES = {
  'getEpochState(bytes32)':  '0xb0a9498c',
  'getPoolConfig(bytes32)':  '0x037aadbe',
  'isInitialized(bytes32)':  '0xf7b637bb',
}

async function callContract(funcSig, poolId) {
  const sighash = SIGHASHES[funcSig]
  if (!sighash) throw new Error('Unknown function: ' + funcSig)
  const data = sighash + poolId.slice(2).padStart(64, '0')
  return rpcCall('eth_call', [{ to: CONFIG.brook, data }, 'latest'])
}

function parseEpochState(hex) {
  const h = hex.slice(2)
  const buffer     = BigInt('0x' + h.slice(0, 64))
  const prevBuffer = BigInt('0x' + h.slice(64, 128))
  const totalScore = BigInt('0x' + h.slice(128, 192))
  const lastUpdate = Number(BigInt('0x' + h.slice(192, 256)))
  const tick       = Number(BigInt('0x' + h.slice(256, 320)) & BigInt('0xFFFFFF'))
  return { buffer, prevBuffer, totalScore, lastUpdateTime: lastUpdate, currentTick: tick }
}

function parsePoolConfig(hex) {
  const h = hex.slice(2)
  const epochLength      = Number(BigInt('0x' + h.slice(0, 64)))
  const startTime        = Number(BigInt('0x' + h.slice(64, 128)))
  const smoothingFee     = Number(BigInt('0x' + h.slice(128, 192)))
  const inRangeMultiplier = Number(BigInt('0x' + h.slice(192, 256)))
  return { epochLength, startTime, smoothingFee, inRangeMultiplier }
}

function fmt(n, decimals = 0) {
  if (n === undefined || n === null) return '—'
  const num = typeof n === 'bigint' ? Number(n) : n
  if (decimals === 0) return num.toLocaleString()
  return num.toFixed(decimals)
}

function shortAddr(addr) {
  if (!addr) return ''
  return addr.slice(0, 6) + '...' + addr.slice(-4)
}

function epochProgress(lastUpdateTime, epochLength) {
  if (!lastUpdateTime || !epochLength) return 0
  const now = Math.floor(Date.now() / 1000)
  const elapsed = now - lastUpdateTime
  return Math.min(1, Math.max(0, elapsed / epochLength))
}

function secondsToHuman(s) {
  if (s <= 0) return '0s'
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}

// ─── Components ───────────────────────────────────────────────────────────────

function LogoMark({ size = 34 }) {
  return (
    <div className="logo-svg" style={{ width: size, height: size, borderRadius: size * 0.29 }}>
      <svg width={size * 0.55} height={size * 0.55} viewBox="0 0 20 20" fill="none">
        <path d="M1 11 Q 5 7, 9.5 11 T 17 11 T 20 11"
          stroke="white" strokeWidth="2" strokeLinecap="round" fill="none"/>
        <path d="M1 15 Q 5 11, 9.5 15 T 17 15 T 20 15"
          stroke="white" strokeWidth="2" strokeLinecap="round" fill="none" opacity="0.55"/>
      </svg>
    </div>
  )
}

function EpochRing({ progress, daysLeft }) {
  const r = 48
  const circ = 2 * Math.PI * r
  const dash = circ * progress
  const gap  = circ - dash

  return (
    <div className="epoch-ring-wrap">
      <div className="epoch-ring">
        <svg width="120" height="120" viewBox="0 0 120 120">
          <circle cx="60" cy="60" r={r}
            fill="none" stroke="rgba(29,158,117,0.08)" strokeWidth="8"/>
          <circle cx="60" cy="60" r={r}
            fill="none"
            stroke="url(#ring-grad)"
            strokeWidth="8"
            strokeLinecap="round"
            strokeDasharray={`${dash} ${gap}`}
            style={{ transition: 'stroke-dasharray 1s ease' }}
          />
          <defs>
            <linearGradient id="ring-grad" x1="0" y1="0" x2="1" y2="0">
              <stop offset="0%" stopColor="#0f6e56"/>
              <stop offset="100%" stopColor="#25c994"/>
            </linearGradient>
          </defs>
        </svg>
        <div className="epoch-ring-center">
          <span className="epoch-ring-pct">{Math.round(progress * 100)}%</span>
          <span className="epoch-ring-label">elapsed</span>
        </div>
      </div>
      <div className="epoch-days">
        {daysLeft > 0 ? `${secondsToHuman(daysLeft)} remaining` : 'epoch ending soon'}
      </div>
    </div>
  )
}

function BufferChart({ history }) {
  if (!history || history.length < 2) {
    return (
      <div className="chart-wrap" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <span style={{ fontSize: 11, color: 'var(--ink-muted)' }}>accumulating data...</span>
      </div>
    )
  }

  const max = Math.max(...history.map(d => Number(d.buffer)), 1)
  const w = 600
  const h = 160
  const pad = { top: 16, right: 16, bottom: 28, left: 48 }
  const iw = w - pad.left - pad.right
  const ih = h - pad.top - pad.bottom

  const pts = history.map((d, i) => {
    const x = pad.left + (i / (history.length - 1)) * iw
    const y = pad.top + ih - (Number(d.buffer) / max) * ih
    return `${x},${y}`
  })

  const area = `M${pts[0]} L${pts.join(' L')} L${pad.left + iw},${pad.top + ih} L${pad.left},${pad.top + ih} Z`
  const line = `M${pts[0]} L${pts.join(' L')}`

  return (
    <div className="chart-wrap">
      <svg viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none">
        <defs>
          <linearGradient id="area-grad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#1d9e75" stopOpacity="0.25"/>
            <stop offset="100%" stopColor="#1d9e75" stopOpacity="0.02"/>
          </linearGradient>
        </defs>
        {/* grid lines */}
        {[0.25, 0.5, 0.75, 1].map(f => (
          <line key={f}
            x1={pad.left} y1={pad.top + ih - f * ih}
            x2={pad.left + iw} y2={pad.top + ih - f * ih}
            stroke="rgba(29,158,117,0.08)" strokeWidth="1"
          />
        ))}
        {/* area */}
        <path d={area} fill="url(#area-grad)"/>
        {/* line */}
        <path d={line} fill="none" stroke="#1d9e75" strokeWidth="1.5"
          strokeLinejoin="round" strokeLinecap="round"/>
        {/* dots */}
        {pts.map((pt, i) => {
          const [x, y] = pt.split(',')
          return <circle key={i} cx={x} cy={y} r="3" fill="#25c994"/>
        })}
        {/* y axis labels */}
        {[0, 0.5, 1].map(f => (
          <text key={f} className="chart-axis"
            x={pad.left - 6} y={pad.top + ih - f * ih + 4}
            textAnchor="end">
            {fmt(Math.round(f * max))}
          </text>
        ))}
        {/* x label */}
        <text className="chart-axis"
          x={pad.left + iw / 2} y={h - 4}
          textAnchor="middle">epoch buffer over time</text>
      </svg>
    </div>
  )
}

function WalletBar({ address, onConnect, onDisconnect }) {
  if (!address) {
    return (
      <div className="wallet-bar">
        <span style={{ color: 'var(--ink-muted)', fontSize: 12 }}>
          Connect wallet to view your position and claim yield
        </span>
        <button className="btn btn-ghost" onClick={onConnect} style={{ padding: '8px 16px', fontSize: 12 }}>
          Connect Wallet
        </button>
      </div>
    )
  }
  return (
    <div className="wallet-bar">
      <span className="wallet-addr">{address}</span>
      <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
        <span className="wallet-badge">Unichain Sepolia</span>
        <button className="btn btn-ghost" onClick={onDisconnect}
          style={{ padding: '6px 12px', fontSize: 11 }}>
          Disconnect
        </button>
      </div>
    </div>
  )
}

// ─── Main App ─────────────────────────────────────────────────────────────────

const MOCK_POSITIONS = [
  { lp: 'Amara', addr: '0x1234...5678', liquidity: '1,000', inRange: true,  score: '892,400', vested: '142' },
  { lp: 'Kofi',  addr: '0xabcd...ef01', liquidity: '500',   inRange: false, score: '312,100', vested: '49' },
  { lp: 'Zara',  addr: '0x9876...4321', liquidity: '750',   inRange: true,  score: '671,200', vested: '107' },
]

export default function App() {
  const [epoch, setEpoch]     = useState(null)
  const [config, setConfig]   = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError]     = useState(null)
  const [history, setHistory] = useState([])
  const [wallet, setWallet]   = useState(null)
  const [claiming, setClaiming] = useState(false)
  const [claimed, setClaimed]   = useState(false)
  const [lastRefresh, setLastRefresh] = useState(null)

  const fetchState = useCallback(async () => {
    try {
      const [epochHex, configHex] = await Promise.all([
        callContract('getEpochState(bytes32)', CONFIG.poolId),
        callContract('getPoolConfig(bytes32)', CONFIG.poolId),
      ])
      const e = parseEpochState(epochHex)
      const c = parsePoolConfig(configHex)
      setEpoch(e)
      setConfig(c)
      setHistory(prev => {
        const next = [...prev, { buffer: e.buffer, t: Date.now() }]
        return next.slice(-20) // keep last 20 readings
      })
      setLastRefresh(new Date())
      setError(null)
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchState()
    const interval = setInterval(fetchState, 15000) // refresh every 15s
    return () => clearInterval(interval)
  }, [fetchState])

  async function connectWallet() {
    if (!window.ethereum) {
      alert('MetaMask not detected. Please install MetaMask.')
      return
    }
    try {
      const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' })
      setWallet(accounts[0])
      // Switch to Unichain Sepolia
      try {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: '0x' + CONFIG.chainId.toString(16) }],
        })
      } catch {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: '0x' + CONFIG.chainId.toString(16),
            chainName: 'Unichain Sepolia',
            rpcUrls: [CONFIG.rpc],
            nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
            blockExplorerUrls: [CONFIG.explorer],
          }],
        })
      }
    } catch (err) {
      console.error(err)
    }
  }

  function disconnectWallet() { setWallet(null) }

  async function handleClaim() {
    if (!wallet || !window.ethereum) return
    setClaiming(true)
    try {
      // For demo: show success after simulated tx
      await new Promise(r => setTimeout(r, 2000))
      setClaimed(true)
      setTimeout(() => setClaimed(false), 4000)
    } catch (err) {
      console.error(err)
    } finally {
      setClaiming(false)
    }
  }

  const progress  = epoch && config
    ? epochProgress(epoch.lastUpdateTime, config.epochLength || CONFIG.epochLength)
    : 0

  const daysLeft  = epoch && config
    ? Math.max(0, (config.epochLength || CONFIG.epochLength) - (Math.floor(Date.now() / 1000) - epoch.lastUpdateTime))
    : 0

  const bufferPct = epoch && epoch.prevBuffer > 0n
    ? Math.min(100, Number(epoch.buffer * 100n / epoch.prevBuffer))
    : epoch ? Math.min(100, Number(epoch.buffer) / 100) : 0

  return (
    <div className="app">
      {/* NAV */}
      <nav className="nav">
        <div className="nav-logo">
          <LogoMark size={34}/>
          Brook
        </div>
        <div className="nav-meta">
        <span className="live-dot">live</span>
        <a className="nav-link" href="https://github.com/Fatumayattani/brook"
      target="_blank" rel="noopener noreferrer">GitHub</a>
    </div>
      </nav>

  <div className="hero">
  <h1 className="hero-title">
    <em>Steady yield</em><br/>for committed LPs.
  </h1>
  <p className="hero-sub">
    Fees in. Paycheck out.
  </p>
  </div>

      {/* WALLET BAR */}
      <WalletBar address={wallet} onConnect={connectWallet} onDisconnect={disconnectWallet}/>

      {/* ERROR */}
      {error && (
        <div className="error-banner">
          RPC error: {error} · <button onClick={fetchState}
            style={{ background: 'none', border: 'none', color: 'inherit', cursor: 'pointer', textDecoration: 'underline' }}>
            retry
          </button>
        </div>
      )}

      {/* STAT CARDS */}
      <div className="grid">
        <div className="card">
          <div className="card-label">epoch buffer</div>
          {loading
            ? <div className="skeleton"/>
            : <div className="card-value">{epoch ? fmt(Number(epoch.buffer)) : '—'}</div>
          }
          <div className="card-sub">fees accumulated this epoch</div>
          {epoch && (
            <div className="buffer-section">
              <div className="buffer-label-row">
                <span>filling</span>
                <span>{bufferPct.toFixed(1)}%</span>
              </div>
              <div className="buffer-track">
                <div className="buffer-fill" style={{ width: bufferPct + '%' }}/>
              </div>
            </div>
          )}
        </div>

        <div className="card">
          <div className="card-label">prev buffer (streaming)</div>
          {loading
            ? <div className="skeleton"/>
            : <div className="card-value amber">{epoch ? fmt(Number(epoch.prevBuffer)) : '—'}</div>
          }
          <div className="card-sub">last epoch · paying out now</div>
        </div>

        <div className="card" style={{ display: 'flex', flexDirection: 'column' }}>
          <div className="card-label">epoch progress</div>
          {loading
            ? <div className="skeleton" style={{ height: 120 }}/>
            : <EpochRing progress={progress} daysLeft={daysLeft}/>
          }
        </div>
      </div>

      {/* BUFFER CHART + POOL INFO */}
      <div className="grid-wide">
        <div className="card">
          <div className="card-label">buffer accumulation</div>
          <BufferChart history={history}/>
        </div>

        <div className="card">
          <div className="card-label">pool config</div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16, marginTop: 8 }}>
            {[
              { label: 'epoch length',     value: config ? secondsToHuman(config.epochLength || CONFIG.epochLength) : '—' },
              { label: 'smoothing fee',    value: config ? (config.smoothingFee / 100).toFixed(1) + '%' : '—' },
              { label: 'in-range mult',    value: config ? config.inRangeMultiplier + 'x' : '—' },
              { label: 'current tick',     value: epoch  ? epoch.currentTick : '—' },
              { label: 'pool id',          value: shortAddr(CONFIG.poolId), mono: true },
            ].map(({ label, value, mono }) => (
              <div key={label} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontSize: 11, color: 'var(--ink-muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{label}</span>
                <span style={{ fontSize: 13, color: 'var(--teal-bright)', fontFamily: mono ? 'var(--mono)' : 'inherit' }}>{value}</span>
              </div>
            ))}
          </div>
          <div style={{ marginTop: 20, paddingTop: 16, borderTop: '1px solid var(--border)' }}>
            <div style={{ fontSize: 10, color: 'var(--ink-muted)', marginBottom: 6 }}>last refresh</div>
            <div style={{ fontSize: 11, color: 'var(--ink-soft)', fontFamily: 'var(--mono)' }}>
              {lastRefresh ? lastRefresh.toLocaleTimeString() : '—'} · auto every 15s
            </div>
          </div>
        </div>
      </div>

      {/* CLAIM */}
      <div className="grid-full">
        <div className="card claim-card">
          <div className="card-label">yield claim</div>
          <div className="claim-row">
            <div className="claim-info">
              <div style={{ fontSize: 11, color: 'var(--ink-muted)', marginBottom: 4 }}>your vested yield</div>
              <div className="claim-amount">
                {wallet
                  ? claimed ? '✓ claimed' : fmt(Number(epoch?.prevBuffer || 0n) > 0 ? 107 : 0)
                  : '—'
                }
              </div>
              <div className="claim-desc">
                {wallet
                  ? 'Based on your in-range time this epoch. Score is weighted — LPs who stayed in range earn more.'
                  : 'Connect your wallet to see your vested yield and claim.'
                }
              </div>
            </div>
            <div className="claim-actions">
              <button
                className="btn btn-primary"
                onClick={handleClaim}
                disabled={!wallet || claiming || claimed || Number(epoch?.prevBuffer || 0n) === 0}
              >
                {claiming ? 'claiming...' : claimed ? 'claimed ✓' : 'claim yield'}
              </button>
              <a
                href={`${CONFIG.explorer}/address/${CONFIG.brook}`}
                target="_blank" rel="noopener noreferrer"
                className="btn btn-ghost"
              >
                explorer ↗
              </a>
            </div>
          </div>
        </div>
      </div>

      {/* LP POSITIONS TABLE */}
      <div className="grid-full">
        <div className="card">
          <div className="card-label">lp positions · demo data</div>
          <table className="pos-table" style={{ marginTop: 16 }}>
            <thead>
              <tr>
                <th>LP</th>
                <th>address</th>
                <th>liquidity</th>
                <th>in range</th>
                <th>score</th>
                <th>vested</th>
              </tr>
            </thead>
            <tbody>
              {MOCK_POSITIONS.map(p => (
                <tr key={p.lp}>
                  <td style={{ color: 'var(--ink)', fontWeight: 500 }}>{p.lp}</td>
                  <td className="mono">{p.addr}</td>
                  <td className="mono green">{p.liquidity}</td>
                  <td>
                    <span className={`in-range-pill ${p.inRange ? 'yes' : 'no'}`}>
                      {p.inRange ? '● in range' : '○ out'}
                    </span>
                  </td>
                  <td className="mono">{p.score}</td>
                  <td className="mono green">{p.vested}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <div style={{ marginTop: 12, fontSize: 11, color: 'var(--ink-muted)' }}>
            Amara, Kofi, and Zara — three LPs, same pool, different ranges. Score reflects who actually showed up.
          </div>
        </div>
      </div>

      {/* CONTRACT ADDRESSES */}
      <div className="grid-full">
        <div className="card">
          <div className="card-label">deployed contracts · Unichain Sepolia</div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(280px, 1fr))', gap: 12, marginTop: 16 }}>
            {[
              { label: 'Brook Hook',   addr: CONFIG.brook },
              { label: 'PoolManager',  addr: CONFIG.poolManager },
              { label: 'Token0 (BTA)', addr: CONFIG.token0 },
              { label: 'Token1 (BTB)', addr: CONFIG.token1 },
            ].map(({ label, addr }) => (
              <div key={label} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                <span style={{ fontSize: 10, color: 'var(--ink-muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>{label}</span>
                <a
                  href={`${CONFIG.explorer}/address/${addr}`}
                  target="_blank" rel="noopener noreferrer"
                  style={{ color: 'var(--teal)', fontFamily: 'var(--mono)', fontSize: 12, textDecoration: 'none' }}
                >
                  {addr}
                </a>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* FOOTER */}
      <footer className="footer">
  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
    <LogoMark size={22}/>
    <span>Brook · Pre-audit, pre-mainnet</span>
  </div>
  <div style={{ display: 'flex', gap: 20 }}>
    <a href="https://github.com/Fatumayattani/brook" target="_blank" rel="noopener noreferrer">GitHub</a>
    <a href="https://atrium.academy/uniswap" target="_blank" rel="noopener noreferrer">UHI9 · Atrium</a>
    <a href="https://docs.uniswap.org/contracts/v4" target="_blank" rel="noopener noreferrer">Uniswap v4</a>
  </div>
</footer>
    </div>
  )
}