module.exports = {
  content: [
    "../lib/**/*.{ex,heex}",
    "../test/**/*.{exs,heex}"
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"],
        mono: ["JetBrains Mono", "ui-monospace", "SFMono-Regular", "monospace"],
        display: ["Georgia", "Cambria", "Times New Roman", "serif"]
      },
      colors: {
        glass: {
          mura: "rgba(15, 23, 42, 0.6)",
          border: "rgba(255, 255, 255, 0.08)",
          highlight: "rgba(255, 255, 255, 0.15)"
        },
        neon: {
          blue: "#3b82f6",
          cyan: "#06b6d4",
          emerald: "#10b981",
          red: "#ef4444",
          purple: "#8b5cf6",
          amber: "#f59e0b",
          pink: "#ec4899"
        },
        fog: "rgba(0,0,0,0.35)",
        kill: "#ef4444",
        heal: "#22c55e",
        water: "#3b82f6"
      },
      opacity: {
        3: "0.03",
        8: "0.08"
      },
      boxShadow: {
        glass: "0 8px 32px rgba(0, 0, 0, 0.37)",
        "neon-blue": "0 0 10px rgba(59, 130, 246, 0.5), 0 0 20px rgba(59, 130, 246, 0.3)",
        "neon-cyan": "0 0 10px rgba(6, 182, 212, 0.5), 0 0 20px rgba(6, 182, 212, 0.3)",
        "neon-emerald": "0 0 10px rgba(16, 185, 129, 0.5), 0 0 20px rgba(16, 185, 129, 0.3)",
        "neon-red": "0 0 10px rgba(239, 68, 68, 0.5), 0 0 20px rgba(239, 68, 68, 0.3)"
      },
      backgroundImage: {
        "gradient-radial": "radial-gradient(var(--tw-gradient-stops))",
        "cyber-grid": "linear-gradient(rgba(15, 23, 42, 0.8) 1px, transparent 1px), linear-gradient(90deg, rgba(15, 23, 42, 0.8) 1px, transparent 1px)"
      }
    }
  },
  plugins: []
}
