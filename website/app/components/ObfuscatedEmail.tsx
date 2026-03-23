"use client";

import { useState, useEffect } from "react";

export function ObfuscatedEmail({ user, domain }: { user: string; domain: string }) {
  const [email, setEmail] = useState("");

  useEffect(() => {
    setEmail(`${user}@${domain}`);
  }, [user, domain]);

  if (!email) return <span className="gradient-text">[loading]</span>;

  return (
    <a
      href={`mailto:${email}`}
      className="gradient-text hover:opacity-80 transition-opacity"
    >
      {email}
    </a>
  );
}
