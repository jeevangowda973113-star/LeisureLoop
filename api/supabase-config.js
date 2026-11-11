export default function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Content-Type", "application/json");
  const supabaseUrl = process.env.SUPABASE_URL || process.env.supabaseurl;
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.supabase_publishable_key;
  if (!supabaseUrl || !publishableKey) {
    return res.status(503).json({ error: "Supabase configuration is missing. Check the Vercel environment variable names." });
  }
  return res.status(200).json({ supabaseUrl, publishableKey });
}
