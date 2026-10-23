fn main() {
    let mut parts: Vec<&str> = Vec::new();
    #[cfg(feature = "vulnerable")]
    {
        let mut values: smallvec::SmallVec<[u8; 4]> = smallvec::SmallVec::new();
        values.push(1);
        parts.push(if values.len() == 1 { "smallvec" } else { "?" });
    }
    #[cfg(feature = "backend-a")]
    parts.push(rso_backend_a::name());
    #[cfg(feature = "backend-b")]
    parts.push(rso_backend_b::name());
    println!("rso-fixture: {}", parts.join(", "));
}
