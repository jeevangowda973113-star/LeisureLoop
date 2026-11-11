export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Content-Type", "application/json");
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed." });
  }

  const supabaseUrl = process.env.SUPABASE_URL || process.env.supabaseurl;
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.supabase_publishable_key;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !publishableKey || !serviceRoleKey) {
    return res.status(503).json({ error: "Account deletion is not configured yet. Please contact LeisureLoop support." });
  }

  const authorization = req.headers.authorization || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) return res.status(401).json({ error: "Please log in again." });
  if (req.body?.confirmation !== "DELETE") {
    return res.status(400).json({ error: "Deletion confirmation is required." });
  }

  try {
    const userResponse = await fetch(supabaseUrl + "/auth/v1/user", {
      headers: { apikey: publishableKey, Authorization: "Bearer " + match[1] }
    });
    if (!userResponse.ok) return res.status(401).json({ error: "Your session is invalid or expired. Please log in again." });
    const user = await userResponse.json();
    if (!user?.id) return res.status(401).json({ error: "Could not verify your account." });

    const deleteResponse = await fetch(supabaseUrl + "/auth/v1/admin/users/" + encodeURIComponent(user.id), {
      method: "DELETE",
      headers: { apikey: serviceRoleKey, Authorization: "Bearer " + serviceRoleKey }
    });
    if (!deleteResponse.ok) {
      const details = await deleteResponse.json().catch(() => ({}));
      console.error("Supabase account deletion failed:", deleteResponse.status, details.msg || details.message || details.error);
      return res.status(502).json({ error: "Supabase could not delete this account. Please contact support." });
    }
    return res.status(200).json({ success: true });
  } catch (error) {
    console.error("Account deletion endpoint failed:", error);
    return res.status(500).json({ error: "Account deletion could not be completed. Please try again." });
  }
}
