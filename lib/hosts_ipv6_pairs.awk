# lib/hosts_ipv6_pairs.awk -- give every live "0.0.0.0 domain" block a
# ":: domain" twin on the next line.
#
# The upstream list is IPv4-only, and an IPv4-only entry lets AAAA lookups fall
# through to DNS, so the site still loads over IPv6. Run as
#   awk -f hosts_ipv6_pairs.awk FILE FILE
# The first pass collects domains that already have a :: line (the custom
# entries carry some), so no pair is ever written twice. Commented-out lines
# (the unblocks) are copied unchanged and get no pair.

# Pass 1: remember every domain already blocked over IPv6.
NR == FNR {
	if ($1 == "::")
		for (i = 2; i <= NF && $i !~ /^#/; i++)
			have[$i] = 1
	next
}

# Pass 2: copy each line, then add the missing :: twins right after it.
{
	print
	if ($1 != "0.0.0.0")
		next
	for (i = 2; i <= NF && $i !~ /^#/; i++) {
		if ($i == "0.0.0.0" || ($i in have))
			continue
		print ":: " $i
		have[$i] = 1
	}
}
