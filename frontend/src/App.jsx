import { useState } from 'react';

function BrookWaves() {
  return (
    <div className="brook-bg" aria-hidden="true">
      <svg className="wave-1" viewBox="0 0 1200 200" preserveAspectRatio="none">
        <path
          d="M0,100 C150,150 350,50 600,100 C850,150 1050,50 1200,100 L1200,200 L0,200 Z"
          fill="#1d9e75"
        />
      </svg>
      <svg className="wave-2" viewBox="0 0 1200 200" preserveAspectRatio="none">
        <path
          d="M0,120 C200,70 400,170 600,120 C800,70 1000,170 1200,120 L1200,200 L0,200 Z"
          fill="#0f6e56"
        />
      </svg>
      <svg className="wave-3" viewBox="0 0 1200 200" preserveAspectRatio="none">
        <path
          d="M0,140 C250,100 450,180 700,140 C950,100 1100,180 1200,140 L1200,200 L0,200 Z"
          fill="#085041"
        />
      </svg>
    </div>
  );
}

function LogoMark() {
  return (
    <div className="logo-mark">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <path
          d="M2 9 Q 4.5 6, 7 9 T 12 9 T 16 9"
          stroke="white"
          strokeWidth="1.6"
          strokeLinecap="round"
          fill="none"
        />
        <path
          d="M2 12 Q 4.5 9, 7 12 T 12 12 T 16 12"
          stroke="white"
          strokeWidth="1.6"
          strokeLinecap="round"
          fill="none"
          opacity="0.6"
        />
      </svg>
    </div>
  );
}

function EmailForm() {
  const [email, setEmail] = useState('');
  const [submitted, setSubmitted] = useState(false);

  const handleSubmit = (e) => {
    e.preventDefault();
    if (!email || !email.includes('@')) return;
    // For now, just simulate submission. Wire up to Netlify Forms or Formspree later.
    setSubmitted(true);
  };

  if (submitted) {
    return (
      <div className="cta-success">
        <span>👋</span> Thanks. We'll be in touch.
      </div>
    );
  }

  return (
    <form
      className="cta-form"
      onSubmit={handleSubmit}
      name="early-access"
      data-netlify="true"
    >
      <input
        type="email"
        name="email"
        placeholder="your@email.com"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        required
        aria-label="Email address"
      />
      <button type="submit">
        Get early access
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
          <path
            d="M3 7h8m0 0L7 3m4 4l-4 4"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </button>
    </form>
  );
}

function HowItWorks() {
  const steps = [
    {
      num: '01',
      title: 'Fees fill the buffer',
      body: 'A small slice of every swap goes into the current epoch\'s buffer, instead of paying out instantly.',
    },
    {
      num: '02',
      title: 'Epoch rolls over',
      body: 'Each week, the buffer becomes the next epoch\'s payout pool, ready to stream out gently.',
    },
    {
      num: '03',
      title: 'LPs get a paycheck',
      body: 'Smooth, predictable yield over the next epoch, weighted by who actually showed up in-range.',
    },
  ];

  return (
    <section className="section" id="how">
      <div className="container">
        <h2 className="section-title">How Brook flows</h2>
        <p className="section-sub">
          Lumpy swap fees in, steady LP yield out. The kind of income you can plan around.
        </p>
        <div className="cards">
          {steps.map((step) => (
            <div className="card" key={step.num}>
              <div className="card-num">{step.num}</div>
              <h3>{step.title}</h3>
              <p>{step.body}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function ForWho() {
  const audiences = [
    'DAO treasuries',
    'Stablecoin LPs',
    'LST and LRT pools',
    'Structured products',
    'Yield aggregators',
    'Tokenized RWAs',
  ];

  return (
    <section className="section who" id="who">
      <div className="container">
        <h2 className="section-title">Built for serious capital</h2>
        <p className="section-sub">
          The kind of LPs who need predictable cash flows for governance, accounting, or balance sheets.
        </p>
        <div className="who-list">
          {audiences.map((a) => (
            <div className="who-item" key={a}>
              <div className="who-icon" />
              {a}
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

export default function App() {
  return (
    <>
      <BrookWaves />

      <div className="container">
        <nav>
          <div className="logo">
            <LogoMark />
            Brook
          </div>
          <div className="nav-links">
            <a href="#how">How it works</a>
            <a href="#who">For who</a>
            <a
              href="https://github.com/Fatumayattani/brook"
              target="_blank"
              rel="noopener noreferrer"
            >
              GitHub
            </a>
          </div>
        </nav>

        <header className="hero">
          <div className="badge">
            <span className="badge-dot" />
            Built during UHI9 · Coming June 2026
          </div>

          <h1>
            A <em>steady stream</em><br />of LP yield.
          </h1>

          <p className="tagline">
            Brook is a Uniswap v4 hook that turns lumpy swap fees into predictable,
            paycheck-style LP yield — weighted by who actually showed up.
          </p>

          <EmailForm />

          <p className="cta-note">No spam. Just a heads-up when Brook is live.</p>
        </header>
      </div>

      <HowItWorks />
      <ForWho />

      <footer>
        <div className="container">
          <div className="footer-row">
            <div className="logo">
              <LogoMark />
              Brook
            </div>
            <div className="footer-links">
              <a
                href="https://github.com/Fatumayattani/brook"
                target="_blank"
                rel="noopener noreferrer"
              >
                GitHub
              </a>
              <a
                href="https://atrium.academy/uniswap"
                target="_blank"
                rel="noopener noreferrer"
              >
                UHI9
              </a>
              <a
                href="https://docs.uniswap.org/contracts/v4"
                target="_blank"
                rel="noopener noreferrer"
              >
                Uniswap v4
              </a>
            </div>
          </div>
          <p className="footer-note">
            Pre-audit, pre-mainnet. Built with care during the Uniswap Hook Incubator.
          </p>
        </div>
      </footer>
    </>
  );
}
