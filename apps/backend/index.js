const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');

const app = express();
const port = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

// Database connection configuration
// These should be provided via environment variables in Kubernetes
const pool = new Pool({
  user: process.env.DB_USER || 'postgres',
  host: process.env.DB_HOST || 'database-service',
  database: process.env.DB_NAME || 'gitopsdb',
  password: process.env.DB_PASSWORD || 'postgres',
  port: process.env.DB_PORT || 5432,
});

// Create a simple table if it doesn't exist to test DB connection
const initDb = async () => {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS requests (
        id SERIAL PRIMARY KEY,
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        ip_address VARCHAR(45)
      )
    `);
    console.log('Database initialized successfully');
  } catch (err) {
    console.error('Error initializing database:', err);
  }
};

// Retry mechanism for database initialization (useful when DB pod starts slower)
setTimeout(initDb, 5000);

// Simple status endpoint
app.get('/status', async (req, res) => {
  try {
    // Log the request to the database
    await pool.query('INSERT INTO requests (ip_address) VALUES ($1)', [req.ip]);
    
    // Get count of requests
    const result = await pool.query('SELECT COUNT(*) FROM requests');
    const count = result.rows[0].count;

    res.json({
      status: 'ok',
      message: 'Backend is running!',
      db_connection: 'successful',
      total_requests: count,
      timestamp: new Date().toISOString()
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({
      status: 'error',
      message: 'Failed to connect to database',
      error: err.message
    });
  }
});

app.listen(port, () => {
  console.log(`Backend API listening on port ${port}`);
});

