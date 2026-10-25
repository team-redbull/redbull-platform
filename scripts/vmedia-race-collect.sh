#!/usr/bin/env bash
# Per-BMH evidence for the InsertMedia -> Power On race after a real MCE install.
# For every BMH it finds the backing VM, its current state, and the order of
# the relevant kubevirt-redfish log events for the first virtual-media cycle:
#
#   JOB    insert job dequeued by a worker ("Inserting virtual media ... for VM")
#   LABEL  importing label set              ("Set importing label ... on VM")
#   ON     VM actually started              ("Successfully started VM")
#   DEFER  power On deferred                ("Power action On deferred for VM")
#   UNLBL  import finished, label removed   ("Removed importing label ... from VM")
#
# Verdict RACE = the VM was first started while its import was still pending
# (ON before UNLBL, or ON with no UNLBL at all). ON is the first start in the
# log, even before JOB: Power On can arrive while the insert job is queued.
# Restart the redfish pod before each run (a helm upgrade does) so the log
# only holds that run.
#
#   BMH_NS=inventory VM_NS=inventory RF_NS=<ns> RF_DEPLOY=<deploy> scripts/vmedia-race-collect.sh
#
# Required env: BMH_NS, VM_NS, RF_NS (redfish namespace), RF_DEPLOY (redfish deployment)
# Optional env: LOGFILE (analyse a saved log instead of fetching), SYS_PREFIX ("$VM_NS." for enhanced IDs)
set -u
: "${BMH_NS:?}" "${VM_NS:?}"
SYS_PREFIX="${SYS_PREFIX:-}"

if [ -z "${LOGFILE:-}" ]; then
	: "${RF_NS:?}" "${RF_DEPLOY:?}"
	LOGFILE="redfish-$(date +%Y%m%d-%H%M%S).log"
	kubectl logs -n "$RF_NS" "deploy/$RF_DEPLOY" --tail=-1 >"$LOGFILE"
	echo "redfish log saved to $LOGFILE"
fi

# Walks the log in order so each event is taken from the first insert cycle:
# eject also logs "Removed importing label", so UNLBL only counts after LABEL.
# The key must end at a delimiter, otherwise "VM ns/vm1" would match "VM ns/vm10".
timeline() { # "VM ns/name" -> "JOB LABEL ON DEFER UNLBL"
	awk -v key="$1" '
	function has(prefix,   i, c) {
		i = index($0, prefix key)
		if (!i) return 0
		c = substr($0, i + length(prefix key), 1)
		return c == "" || c == " " || c == ":" || c == ","
	}
	{
		if (!match($0, /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+/)) next
		t = substr($0, RSTART + 11, 12)
		if (!job && index($0, "Inserting virtual media") && has("for ")) job = t
		else if (job && !lbl && index($0, "Set importing label") && has("on ")) lbl = t
		else if (!on && (has("Successfully started ") || has("Successfully force restarted ") || has("Successfully gracefully restarted "))) on = t
		else if (has("deferred for ")) defer = "yes"
		else if (lbl && !unl && index($0, "Removed importing label") && has("from ")) unl = t
	}
	END { print (job ? job : "-"), (lbl ? lbl : "-"), (on ? on : "-"), (defer ? defer : "no"), (unl ? unl : "-") }
	' "$LOGFILE"
}

printf '%-22s %-20s %-10s %-9s %-6s | %-12s %-12s %-12s %-5s %-12s | %s\n' \
	BMH STATE VMI COPY_POD MULTI JOB LABEL ON DEFER UNLBL VERDICT
while read -r -u 3 bmh addr state; do
	sys="${addr##*/}"
	vm="${sys#"$SYS_PREFIX"}"
	key="VM $VM_NS/$vm"

	vmi=$(kubectl get vmi -n "$VM_NS" "$vm" -o jsonpath='{.status.phase}' 2>/dev/null)
	lbl=$(kubectl get vm -n "$VM_NS" "$vm" -o jsonpath='{.metadata.labels.importing\.redfish/cdrom0}' 2>/dev/null)
	pod="-" ma="-"
	if [ -n "$lbl" ]; then
		pod=$(kubectl get pod -n "$VM_NS" "$lbl" -o jsonpath='{.status.phase}' 2>/dev/null)
		ma=$(kubectl get events -n "$VM_NS" --field-selector "involvedObject.name=$lbl,reason=FailedAttachVolume" -o name 2>/dev/null | wc -l | tr -d ' ')
	fi

	read -r t_job t_lbl t_on defer t_unl <<EOF
$(timeline "$key" </dev/null)
EOF

	# Timestamps are HH:MM:SS.mmm of one run, so string order is time order.
	verdict=ok
	if [ "$t_job" = - ]; then
		verdict="no insert in log"
	elif [ "$t_on" != - ] && { [ "$t_unl" = - ] || [[ "$t_on" < "$t_unl" ]]; }; then
		verdict="RACE (started before label set)"
		[[ "$t_on" < "$t_job" ]] && verdict="RACE (started while insert job queued)"
		[ "$t_lbl" != - ] && [[ "$t_lbl" < "$t_on" ]] && verdict="RACE (started during import)"
	fi

	printf '%-22s %-20s %-10s %-9s %-6s | %-12s %-12s %-12s %-5s %-12s | %s\n' \
		"$bmh" "$state" "${vmi:--}" "${pod:--}" "$ma" "$t_job" "$t_lbl" "$t_on" "$defer" "$t_unl" "$verdict"
done 3< <(kubectl get bmh -n "$BMH_NS" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.bmc.address}{" "}{.status.provisioning.state}{"\n"}{end}')
