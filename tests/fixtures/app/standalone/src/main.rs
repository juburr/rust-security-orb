fn main() {
    let mut values: smallvec::SmallVec<[u8; 4]> = smallvec::SmallVec::new();
    values.push(1);
    println!("rso-standalone: {}", values.len());
}
