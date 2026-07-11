import { useState, useEffect } from "react";

export default function Header() {
  const [pulse, setPulse] = useState(false);
  const [theme, setTheme] = useState<'light' | 'dark'>(() => {
    const saved = localStorage.getItem("theme");
    return (saved === "dark" || saved === "light") ? saved : "light";
  });

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
    localStorage.setItem("theme", theme);
  }, [theme]);

  const toggleTheme = () => {
    setTheme(prev => prev === "light" ? "dark" : "light");
  };

  return (
    <header className="app-header">
      {/* Logo */}
      <div
        className={pulse ? "animate-pulse-ring" : ""}
        onMouseEnter={() => setPulse(true)}
        onMouseLeave={() => setPulse(false)}
        style={{
          width: 38,
          height: 38,
          borderRadius: "12px",
          background: "var(--surface-gradient)",
          boxShadow: "var(--shadow-raised-sm)",
          borderTop: "1px solid var(--border-light)",
          borderLeft: "1px solid var(--border-light)",
          borderBottom: "1px solid var(--border-dark)",
          borderRight: "1px solid var(--border-dark)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          cursor: "default",
          transition: "all var(--transition)",
          flexShrink: 0,
        }}
      >
        <img src="/logo.png" alt="Sigil Logo" width="22" height="22" style={{ pointerEvents: "none", objectFit: "contain" }} />
      </div>
 
      {/* Title */}
      <div>
        <h1 style={{
          fontSize: "18px",
          fontWeight: 800,
          letterSpacing: "-0.02em",
          lineHeight: 1.1,
          background: "linear-gradient(135deg, #f06292, #c2185b)",
          WebkitBackgroundClip: "text",
          WebkitTextFillColor: "transparent",
          backgroundClip: "text",
        }}>
          Sigil Flash
        </h1>
        <p style={{ fontSize: "10px", color: "var(--text-muted)", fontWeight: 500, letterSpacing: "0.06em", textTransform: "uppercase" }}>
          Raspberry Pi Image Flasher
        </p>
      </div>

      <div style={{ flex: 1 }} />

      {/* Status indicator */}
      <div style={{
        display: "flex", alignItems: "center", gap: 6,
        padding: "5px 12px",
        borderRadius: "var(--radius-full)",
        background: "var(--bg-deep)",
        boxShadow: "var(--shadow-inset-sm)",
      }}>
        <div style={{
          width: 7, height: 7, borderRadius: "50%",
          background: "var(--success)",
          boxShadow: "0 0 6px var(--success-shadow)",
          animation: "pulse-ring 2.5s ease infinite",
        }} />
        <span style={{ fontSize: "11px", fontWeight: 600, color: "var(--text-secondary)" }}>Sistema listo</span>
      </div>

      {/* Theme selector button */}
      <button
        onClick={toggleTheme}
        className="btn-icon"
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: "15px",
          width: 36,
          height: 36,
          borderRadius: "12px",
          border: "none",
          cursor: "pointer",
          background: "var(--surface)",
          boxShadow: "var(--shadow-raised-sm)",
          transition: "all var(--transition)",
        }}
        title={theme === "light" ? "Cambiar a modo oscuro" : "Cambiar a modo claro"}
      >
        {theme === "light" ? "🌙" : "☀️"}
      </button>

      {/* Version badge */}
      <div style={{
        padding: "4px 10px",
        borderRadius: "var(--radius-full)",
        background: "var(--accent-bg)",
        boxShadow: "var(--shadow-inset-sm)",
        fontSize: "11px",
        fontWeight: 700,
        color: "var(--accent)",
        letterSpacing: "0.04em",
      }}>
        v0.1.0
      </div>
    </header>
  );
}
