#!/usr/bin/env python3
# PLANTED FAULTS for PeoplePot.sol (CLAUDE.md 2: "Foundry tests with a planted fault per rule"). Each mutant breaks ONE rule in a copy of
# the project; `forge test` must FAIL on it. A survivor means a rule has no test that would notice it breaking.
import os, shutil, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.abspath(__file__))
TARGET = sys.argv[1] if len(sys.argv) > 1 else 'PeoplePot'
M = {
 'PeoplePot': [
  ('only the census publishes', "        if (msg.sender != census) revert NotCensus();\n", ""),
  ('a claim pays the proven person, not the caller', "usdc.transfer(person, e.perPerson)", "usdc.transfer(msg.sender, e.perPerson)"),
  ('a claim needs a valid proof', "        if (!_verify(proof, e.root, leaf)) revert BadProof();\n", ""),
  ('one claim per person per epoch (check)', "        if (claimed[epoch][person]) revert AlreadyClaimed();\n", ""),
  ('one claim per person per epoch (mark)', "        claimed[epoch][person] = true;\n", ""),
  ('per-person cap in the budget', "        if (budget > uint256(count) * maxPerPerson) budget = uint256(count) * maxPerPerson;\n", ""),
  ('per-epoch USDC cap', "        if (budget > maxEpochUsdc) budget = maxEpochUsdc;\n", ""),
  ('per-epoch share of the pot', "uint256 budget = f * maxEpochBps / 10000;", "uint256 budget = f;"),
  ('the free pot excludes what is promised', "return bal > outstanding ? bal - outstanding : 0;", "return bal;"),
  ('an epoch is published once', "        if (epochs[epoch].publishedAt != 0) revert AlreadyPublished();\n", ""),
  ('the claim window closes', "        if (block.timestamp > e.publishedAt + claimWindow) revert ClaimWindowClosed();\n", ""),
  ('release only once', "        if (e.released) revert AlreadyReleased();\n", ""),
  ('release returns only the unclaimed', "uint256 left = uint256(e.perPerson) * e.count - e.paid;", "uint256 left = uint256(e.perPerson) * e.count;"),
  ('a list longer than its count cannot overpay', "        if (uint256(e.paid) + e.perPerson > uint256(e.perPerson) * e.count) revert EpochExhausted();\n", ""),
  ('re-entrancy lock', '        require(_lock == 1, "reentrant");\n', ""),
  ('no publishing before the epoch is over', "        if (block.timestamp < endsAt) revert EpochNotOver();\n", ""),
  ('the publish window closes', "        if (block.timestamp > endsAt + publishWindow) revert PublishWindowClosed();\n", ""),
  ('claims reduce what is promised', "        outstanding -= e.perPerson;\n", ""),
  ('list size limits', "        if (count == 0 || count > maxCount || root == bytes32(0)) revert BadCount();\n", ""),
  ('shares round down', "uint256 per = budget / count;", "uint256 per = (budget + count - 1) / count;"),
  ('an empty share is refused', "        if (per == 0) revert NothingToShare();\n", ""),
  ('release waits for the window', "        if (block.timestamp <= e.publishedAt + claimWindow) revert NotYetReleasable();\n", ""),
  ('total paid is counted', "        totalPaid += e.perPerson;\n", ""),
  ('publishing reserves the money', "        outstanding += per * count;\n", ""),
 ],
 'ImmuneAttestations': [
  ('only the attestor attests', "    modifier onlyAttestor() {\n        if (msg.sender != attestor) revert NotAttestor();\n        _;\n    }", "    modifier onlyAttestor() {\n        _;\n    }"),
  ('grades above 5 are refused', "        if (grade > 5) revert BadGrade();\n", ""),
  ('an empty evidence hash is refused', "        if (evidenceHash == bytes32(0)) revert EmptyEvidence();\n", ""),
  ('the zero token is refused', "        if (token == address(0)) revert ZeroToken();\n", ""),
  ('two-step attestor change: only the proposed accepts', "        if (pendingAttestor == address(0) || msg.sender != pendingAttestor) revert NotPending();\n", ""),
  ('an unset pending attestor cannot be accepted by address zero', "pendingAttestor == address(0) || msg.sender != pendingAttestor", "msg.sender != pendingAttestor"),
  ('only the attestor proposes', "    function proposeAttestor(address next) external onlyAttestor {", "    function proposeAttestor(address next) external {"),
  ('the block number is recorded', "uint64(block.number), uint64(block.timestamp), evidenceHash);\n        attestations++;", "0, uint64(block.timestamp), evidenceHash);\n        attestations++;"),
  ('the attestation is stored', "        _latest[token] = Attestation(grade, uint64(block.number), uint64(block.timestamp), evidenceHash);\n", ""),
  ('batches are bounded', "tokens.length <= 50", "tokens.length <= 5000"),
  ('batch arrays must match', "require(tokens.length == grades.length && tokens.length == hashes.length && tokens.length <= 50, \"batch\");", "require(tokens.length <= 50, \"batch\");"),
 ],
}
src = os.path.join(ROOT, 'src', TARGET + '.sol'); orig = open(src).read()
survived = 0
for name, a, b in M[TARGET]:
    n = orig.count(a)
    if n != 1: print('BAD MUTANT %-60s pattern found %d times' % (name, n)); survived += 1; continue
    d = tempfile.mkdtemp(prefix='mutant-')
    for x in ('foundry.toml', 'test', 'script'): 
        s = os.path.join(ROOT, x); 
        if os.path.isdir(s): shutil.copytree(s, os.path.join(d, x))
        elif os.path.exists(s): shutil.copy(s, d)
    os.symlink(os.path.join(ROOT, 'lib'), os.path.join(d, 'lib')); os.makedirs(os.path.join(d, 'src'))
    for f in os.listdir(os.path.join(ROOT, 'src')): shutil.copy(os.path.join(ROOT, 'src', f), os.path.join(d, 'src', f))
    open(os.path.join(d, 'src', TARGET + '.sol'), 'w').write(orig.replace(a, b))
    env = dict(os.environ, PATH=os.environ['PATH'] + ':' + os.path.expanduser('~/.foundry/bin'), FOUNDRY_INVARIANT_RUNS='96')
    r = subprocess.run(['forge', 'test', '--match-path', 'test/' + TARGET + '*.sol', '-q'], cwd=d, env=env, capture_output=True, text=True, timeout=600)
    killed = r.returncode != 0
    first = ''
    for line in (r.stdout + r.stderr).splitlines():
        if line.startswith('[FAIL') or 'Error:' in line: first = line.strip()[:100]; break
    print(('killed   ' if killed else 'SURVIVED ') + name + ('   ' + first if killed else ''))
    if not killed: survived += 1
    shutil.rmtree(d, ignore_errors=True)
print('\n%d survived' % survived if survived else '\nall %d planted faults were caught' % len(M[TARGET]))
sys.exit(1 if survived else 0)
