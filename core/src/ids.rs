//! Random ids, from the OS CSPRNG, and their hex form.

/// Without a random nonce the hook channel has no authentication at all, so failing here is fatal.
pub(crate) fn random<const N: usize>() -> [u8; N] {
    let mut b = [0; N];
    getrandom::fill(&mut b).expect("OS random source");
    b
}

pub(crate) fn hex(b: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(b.len() * 2);
    for &x in b {
        s.push(DIGITS[usize::from(x >> 4)] as char);
        s.push(DIGITS[usize::from(x & 15)] as char);
    }
    s
}

pub(crate) fn uuid_v4() -> String {
    let mut b: [u8; 16] = random();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex(&b);
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

#[cfg(test)]
mod tests {
    #[test]
    fn hex_and_uuid_shapes() {
        assert_eq!(super::hex(&[0x00, 0x0f, 0xa5, 0xff]), "000fa5ff");
        let u = super::uuid_v4();
        assert_eq!((u.len(), &u[14..15]), (36, "4"));
        assert_ne!(super::random::<16>(), super::random::<16>());
    }
}
