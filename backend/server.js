const express = require("express");
const { Pool } = require("pg");
const cors = require("cors");

const app = express();
const port = Number(process.env.PORT || 3000);

app.use(cors({ origin: process.env.CORS_ORIGIN || "*" }));
app.use(express.json());

const pool = new Pool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME || "fintech",
  port: Number(process.env.DB_PORT || 5432),
  ssl: process.env.DB_SSL === "true" ? { rejectUnauthorized: false } : false,
});

app.get("/api/health", (req, res) => {
  res.json({ status: "ok" });
});

app.get("/api/users", async (req, res) => {
  try {
    const result = await pool.query("SELECT * FROM users ORDER BY id ASC");
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/api/users", async (req, res) => {
  const { name } = req.body;

  if (!name || !name.trim()) {
    return res.status(400).json({ error: "name is required" });
  }

  try {
    const result = await pool.query(
      "INSERT INTO users(name) VALUES($1) RETURNING *",
      [name.trim()]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

async function ensureSchema() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      created_at TIMESTAMPTZ DEFAULT now()
    )
  `);
}

let server;

ensureSchema()
  .then(() => {
    server = app.listen(port, () => {
      console.log(`Backend running on port ${port}`);
    });
  })
  .catch((err) => {
    console.error("Failed to initialize database schema", err);
    process.exit(1);
  });

process.on("SIGTERM", async () => {
  if (!server) {
    await pool.end();
    process.exit(0);
  }

  server.close(async () => {
    await pool.end();
    process.exit(0);
  });
});
