// Fill these in from Supabase â†’ Project Settings â†’ API. The anon key is meant
// to be public: every table is RLS-denied, all access goes through RPCs.
window.CFG = {
  SUPABASE_URL: 'https://YOUR-PROJECT.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR-SUPABASE-ANON-KEY',

  EVENT_NAME: 'KAIZEN POP-CAT',

  // Shown under the QR code on the lobby screen, for anyone whose camera fails.
  // This MUST match what img/qr-join.png actually encodes — if you change the
  // domain, regenerate the QR image too or the room will scan the wrong place.
  JOIN_URL: 'popcat-event.vercel.app',

  // Hard deadline for the whole event. The server caps a "round" at 1 hour, so the
  // game runs in open play (no server round) and the pages count down to this
  // instead. When it passes, both screens flip to FINAL RESULT on their own.
  // Set to null to go back to endless open play.
  EVENT_END: '2026-09-25T23:59:59+07:00',

  // Department dropdown on the join screen. Edit freely.
  DEPARTMENTS: [
    'TSDA', 'TPE', 'Operation', 'PCB', 'QA', 'IE', 'GR', 'PLANNING',
    'SUPPLY CHAIN', 'PMO', 'CSR', 'SHIPPING', 'GTC', 'ACCOUNT', 'PROCUREMENT',
    'FINANCE', 'SEC', 'EHS', 'FAC', 'IT', 'FA LAB', 'Rel Lab', 'FRITZ',
    'Secretary', 'HR'
  ]
};
