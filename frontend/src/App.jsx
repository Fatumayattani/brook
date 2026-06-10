import { useState, useEffect, useCallback } from 'react'
import { ethers } from 'ethers'

// ─── Live deployment · Unichain Sepolia ────────────────────────────────────────
const CONFIG = {
  rpc:         'https://sepolia.unichain.org',
  chainId:     1301,
  chainHex:    '0x515',
  brook:       '0xef91EAf413170cAD2f65B3f05E969759df0AA744',
  router:      '0x57b79d383E951227C9d0479eFd031a7Ca73fB81e',
  token0:      '0x88A0a6C32d773f85d23D66fC5178Fca75Bd82Caf',
  token1:      '0xFb506F1884Dc277f5B21a18Cb90247504D1b61c7',
  poolId:      '0x903bbfd43ff5574d10aca3631527813450b7429f73333766517d1664b9ba3b9d',
  fee:         3000,
  tickSpacing: 60,
  explorer:    'https://unichain-sepolia.blockscout.com',
}

const POOL_KEY_TUPLE = [CONFIG.token0, CONFIG.token1, CONFIG.fee, CONFIG.tickSpacing, CONFIG.brook]

const LIQUIDITY    = 1_000_000n
const MINT_AMOUNT  = ethers.parseEther('100000')
const SWAP_AMOUNT  = -50_000

// ─── ABIs ───────────────────────────────────────────────────────────────────
const BROOK_ABI = [
  'function getEpochState(bytes32) view returns (uint128 buffer, uint128 prevBuffer, uint64 totalScore, uint64 lastUpdateTime, int24 currentTick, int128 lastSkimAmount)',
  'function getPoolConfig(bytes32) view returns (uint64 epochLength, uint64 startTime, uint16 smoothingFee, uint16 inRangeMultiplier)',
  'function getLPState(bytes32, bytes32) view returns (uint128 liquidity, uint64 depositTime, uint64 lastTouched, uint64 totalTime, uint64 inRangeTime, int24 tickLower, int24 tickUpper)',
  'function getFeeCurrency(bytes32) view returns (address)',
]
const ROUTER_ABI = [
  'function addLiquidity((address,address,uint24,int24,address) key, uint256 liquidity)',
  'function swap((address,address,uint24,int24,address) key, bool zeroForOne, int256 amountSpecified)',
  'function claim((address,address,uint24,int24,address) key)',
  'function positionKeyFor(address user) view returns (bytes32)',
]
const ERC20_ABI = [
  'function mint(address to, uint256 amount)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
]

const readProvider = new ethers.JsonRpcProvider(CONFIG.rpc)
const brookRead  = new ethers.Contract(CONFIG.brook, BROOK_ABI, readProvider)
const routerRead = new ethers.Contract(CONFIG.router, ROUTER_ABI, readProvider)

// ─── Helpers ──────────────────────────────────────────────────────────────────
const fmt = (n) => {
  if (n === undefined || n === null) return '—'
  const v = typeof n === 'bigint' ? Number(n) : n
  return v.toLocaleString()
}
const short = (a) => a ? a.slice(0, 6) + '…' + a.slice(-4) : ''
function human(s) {
  if (s <= 0) return 'ready to roll'
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
  if (h > 0) return `${h}h ${m}m`
  if (m > 0) return `${m}m ${sec}s`
  return `${sec}s`
}

// ─── Logo ───────────────────────────────────────────────────────────────────
function LogoMark({ size = 32 }) {
  return (
    <div className="logo-svg" style={{ width: size, height: size, borderRadius: size * 0.28 }}>
      <svg width={size * 0.55} height={size * 0.55} viewBox="0 0 20 20" fill="none">
        <path d="M1 11 Q 5 7, 9.5 11 T 17 11 T 20 11" stroke="white" strokeWidth="2" strokeLinecap="round" fill="none"/>
        <path d="M1 15 Q 5 11, 9.5 15 T 17 15 T 20 15" stroke="white" strokeWidth="2" strokeLinecap="round" fill="none" opacity="0.55"/>
      </svg>
    </div>
  )
}

function EpochRing({ progress }) {
  const r = 46, circ = 2 * Math.PI * r
  const dash = circ * Math.min(1, progress)
  return (
    <div className="ring-wrap">
      <svg width="116" height="116" viewBox="0 0 116 116">
        <circle cx="58" cy="58" r={r} fill="none" stroke="rgba(29,158,117,0.1)" strokeWidth="7"/>
        <circle cx="58" cy="58" r={r} fill="none" stroke="url(#rg)" strokeWidth="7" strokeLinecap="round"
          strokeDasharray={`${dash} ${circ - dash}`} transform="rotate(-90 58 58)"
          style={{ transition: 'stroke-dasharray 1s ease' }}/>
        <defs><linearGradient id="rg" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" stopColor="#0f6e56"/><stop offset="100%" stopColor="#25c994"/>
        </linearGradient></defs>
      </svg>
      <div className="ring-center">
        <span className="ring-pct">{Math.round(Math.min(1, progress) * 100)}%</span>
        <span className="ring-lbl">epoch</span>
      </div>
    </div>
  )
}

export default function App() {
  const [wallet, setWallet]   = useState(null)
  const [signer, setSigner]   = useState(null)
  const [epoch, setEpoch]     = useState(null)
  const [config, setConfig]   = useState(null)
  const [position, setPosition] = useState(null)
  const [balances, setBalances] = useState(null)
  const [busy, setBusy]       = useState(null)
  const [toast, setToast]     = useState(null)
  const [error, setError]     = useState(null)
  const [now, setNow]         = useState(Math.floor(Date.now() / 1000))

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(t)
  }, [])

  const refresh = useCallback(async () => {
    try {
      const [e, c] = await Promise.all([
        brookRead.getEpochState(CONFIG.poolId),
        brookRead.getPoolConfig(CONFIG.poolId),
      ])
      setEpoch({
        buffer: e.buffer, prevBuffer: e.prevBuffer,
        totalScore: e.totalScore, lastUpdateTime: Number(e.lastUpdateTime),
      })
      setConfig({
        epochLength: Number(c.epochLength), startTime: Number(c.startTime),
        smoothingFee: Number(c.smoothingFee), inRangeMultiplier: Number(c.inRangeMultiplier),
      })
      setError(null)
      if (wallet) {
        const pk = await routerRead.positionKeyFor(wallet)
        const lp = await brookRead.getLPState(CONFIG.poolId, pk)
        setPosition({ liquidity: lp.liquidity, totalTime: Number(lp.totalTime), inRangeTime: Number(lp.inRangeTime) })
        const t0 = new ethers.Contract(CONFIG.token0, ERC20_ABI, readProvider)
        const t1 = new ethers.Contract(CONFIG.token1, ERC20_ABI, readProvider)
        const [b0, b1] = await Promise.all([t0.balanceOf(wallet), t1.balanceOf(wallet)])
        setBalances({ token0: b0, token1: b1 })
      }
    } catch (err) {
      setError(err.message || String(err))
    }
  }, [wallet])

  useEffect(() => {
    refresh()
    const i = setInterval(refresh, 12000)
    return () => clearInterval(i)
  }, [refresh])

  async function connect() {
    if (!window.ethereum) { setError('No wallet detected. Install a browser wallet to continue.'); return }
    try {
      const provider = new ethers.BrowserProvider(window.ethereum)
      await provider.send('eth_requestAccounts', [])
      try {
        await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CONFIG.chainHex }] })
      } catch {
        await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [{
          chainId: CONFIG.chainHex, chainName: 'Unichain Sepolia', rpcUrls: [CONFIG.rpc],
          nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, blockExplorerUrls: [CONFIG.explorer],
        }]})
      }
      const s = await provider.getSigner()
      setSigner(s)
      setWallet(await s.getAddress())
    } catch (err) { setError(err.message || String(err)) }
  }

  function showToast(msg, hash) { setToast({ msg, hash }); setTimeout(() => setToast(null), 6000) }

  async function run(action, label, fn) {
    setBusy(action); setError(null)
    try {
      const tx = await fn()
      showToast(`${label} sent`, tx.hash)
      await tx.wait()
      showToast(`${label} confirmed`, tx.hash)
      await refresh()
    } catch (err) {
      setError(err.shortMessage || err.message || String(err))
    } finally { setBusy(null) }
  }

  const tokens = () => ({
    t0: new ethers.Contract(CONFIG.token0, ERC20_ABI, signer),
    t1: new ethers.Contract(CONFIG.token1, ERC20_ABI, signer),
  })
  const router = () => new ethers.Contract(CONFIG.router, ROUTER_ABI, signer)

  const doMint = () => run('mint', 'Mint', async () => {
    const { t0 } = tokens()
    const tx0 = await t0.mint(wallet, MINT_AMOUNT)
    await tx0.wait()
    const { t1 } = tokens()
    return t1.mint(wallet, MINT_AMOUNT)
  })
  const doApprove = () => run('approve', 'Approve', async () => {
    const { t0 } = tokens()
    const tx0 = await t0.approve(CONFIG.router, ethers.MaxUint256)
    await tx0.wait()
    const { t1 } = tokens()
    return t1.approve(CONFIG.router, ethers.MaxUint256)
  })
  const doAddLiquidity = () => run('lp', 'Add liquidity', () => router().addLiquidity(POOL_KEY_TUPLE, LIQUIDITY))
  const doSwap  = () => run('swap', 'Swap', () => router().swap(POOL_KEY_TUPLE, false, SWAP_AMOUNT))
  const doClaim = () => run('claim', 'Claim', () => router().claim(POOL_KEY_TUPLE))

  const epochLen = config?.epochLength || 3600
  const elapsed = epoch ? now - epoch.lastUpdateTime : 0
  const progress = epoch ? elapsed / epochLen : 0
  const timeLeft = epoch ? epochLen - elapsed : 0
  const canRoll = epoch && epoch.lastUpdateTime > 0 && elapsed >= epochLen
  const hasPosition = position && position.liquidity > 0n
  const claimable = epoch && epoch.prevBuffer > 0n && hasPosition

  return (
    <div className="app">
      <nav className="nav">
        <div className="nav-logo"><LogoMark size={32}/> Brook</div>
        <div className="nav-meta">
          <a className="nav-link" href="/docs.html">Docs</a>
          <a className="nav-link" href="/pitch.html">Pitch</a>
          <a className="nav-link" href="https://github.com/Fatumayattani/brook" target="_blank" rel="noreferrer">GitHub</a>
          {wallet
            ? <span className="wallet-pill">{short(wallet)}</span>
            : <button className="btn-ghost sm" onClick={connect}>Connect Wallet</button>}
        </div>
      </nav>

      <header className="hero">
        <h1><em>Steady yield</em> for committed LPs.</h1>
        <p>A live Uniswap v4 hook on Unichain Sepolia. Mint test tokens, provide liquidity, swap, and claim real epoch-vested yield — all from your wallet.</p>
      </header>

      {error && <div className="banner err">{error}</div>}
      {toast && (
        <div className="banner ok">
          {toast.msg}
          {toast.hash && <> · <a href={`${CONFIG.explorer}/tx/${toast.hash}`} target="_blank" rel="noreferrer">view tx ↗</a></>}
        </div>
      )}

      <section className="grid3">
        <div className="card">
          <div className="card-lbl">epoch buffer</div>
          <div className="card-val">{epoch ? fmt(epoch.buffer) : '—'}</div>
          <div className="card-sub">filling now from swaps</div>
        </div>
        <div className="card">
          <div className="card-lbl">prev buffer · streaming</div>
          <div className="card-val amber">{epoch ? fmt(epoch.prevBuffer) : '—'}</div>
          <div className="card-sub">claimable by LPs</div>
        </div>
        <div className="card center">
          <EpochRing progress={progress}/>
          <div className="card-sub" style={{ marginTop: 10 }}>
            {canRoll ? 'epoch ready to roll' : `${human(timeLeft)} left`}
          </div>
        </div>
      </section>

      <section className="card loop">
        <div className="card-lbl">run the loop</div>
        {!wallet && <p className="loop-hint">Connect your wallet to start. You'll need a little Unichain Sepolia ETH for gas.</p>}

        <div className="steps">
          <Step n="1" title="Mint test tokens" done={balances && balances.token0 > 0n}
            desc="Get demo tokens (DTA + DTB) to your wallet."
            btn="Mint tokens" onClick={doMint} busy={busy==='mint'} disabled={!wallet}/>

          <Step n="2" title="Approve the router" done={false}
            desc="Allow the router to move your tokens for LP and swaps."
            btn="Approve" onClick={doApprove} busy={busy==='approve'} disabled={!wallet || !(balances && balances.token0 > 0n)}/>

          <Step n="3" title="Add liquidity" done={hasPosition}
            desc="Provide full-range liquidity. Your position keys to you."
            btn="Add liquidity" onClick={doAddLiquidity} busy={busy==='lp'} disabled={!wallet}/>

          <Step n="4" title="Swap" done={false}
            desc="Swap through the pool. 20% of output skims into the buffer."
            btn="Swap" onClick={doSwap} busy={busy==='swap'} disabled={!wallet}/>

          <Step n="5" title="Roll the epoch" done={epoch && epoch.prevBuffer > 0n}
            desc={canRoll ? 'Epoch expired — one swap rolls the buffer into the payout pool.' : 'Waits for the epoch to expire, then a swap rolls it.'}
            btn="Swap to roll" onClick={doSwap} busy={busy==='swap'} disabled={!wallet || !canRoll}/>

          <Step n="6" title="Claim yield" done={false} highlight={claimable}
            desc="Claim your vested yield. It lands in your wallet."
            btn="Claim yield" onClick={doClaim} busy={busy==='claim'} disabled={!claimable}/>
        </div>
      </section>

      {wallet && (
        <section className="grid2">
          <div className="card">
            <div className="card-lbl">your position</div>
            <div className="kv"><span>liquidity</span><span className="green">{position ? fmt(position.liquidity) : '—'}</span></div>
            <div className="kv"><span>total time</span><span>{position ? human(position.totalTime) : '—'}</span></div>
            <div className="kv"><span>in-range time</span><span className="green">{position ? human(position.inRangeTime) : '—'}</span></div>
          </div>
          <div className="card">
            <div className="card-lbl">your balances</div>
            <div className="kv"><span>DTA</span><span className="mono">{balances ? fmt(ethers.formatEther(balances.token0)).split('.')[0] : '—'}</span></div>
            <div className="kv"><span>DTB</span><span className="mono">{balances ? fmt(ethers.formatEther(balances.token1)).split('.')[0] : '—'}</span></div>
          </div>
        </section>
      )}

      <section className="card">
        <div className="card-lbl">live on Unichain Sepolia</div>
        <div className="contracts">
          {[['Brook hook', CONFIG.brook], ['Router', CONFIG.router], ['Token DTA', CONFIG.token0], ['Token DTB', CONFIG.token1]].map(([label, a]) => (
            <div key={a} className="contract-row">
              <span>{label}</span>
              <a href={`${CONFIG.explorer}/address/${a}`} target="_blank" rel="noreferrer" className="mono">{short(a)} ↗</a>
            </div>
          ))}
        </div>
      </section>

      <footer className="footer">
        <div className="foot-l"><LogoMark size={20}/> Brook · Pre-audit, pre-mainnet</div>
        <div className="foot-r">
          <a href="/docs.html">Docs</a>
          <a href="https://github.com/Fatumayattani/brook" target="_blank" rel="noreferrer">GitHub</a>
          <a href="https://atrium.academy/uniswap" target="_blank" rel="noreferrer">UHI9</a>
        </div>
      </footer>
    </div>
  )
}

function Step({ n, title, desc, btn, onClick, busy, disabled, done, highlight }) {
  return (
    <div className={`step ${done ? 'done' : ''} ${highlight ? 'hot' : ''}`}>
      <div className="step-n">{done ? '✓' : n}</div>
      <div className="step-body">
        <div className="step-title">{title}</div>
        <div className="step-desc">{desc}</div>
      </div>
      <button className="btn-primary sm" onClick={onClick} disabled={disabled || busy}>
        {busy ? '…' : btn}
      </button>
    </div>
  )
}