package cpumanager

import (
	"fmt"

	v1 "k8s.io/api/core/v1"
	utilfeature "k8s.io/apiserver/pkg/util/feature"
	"k8s.io/klog/v2"
	podutil "k8s.io/kubernetes/pkg/api/v1/pod"
	v1qos "k8s.io/kubernetes/pkg/apis/core/v1/helper/qos"
	"k8s.io/kubernetes/pkg/features"
	"k8s.io/kubernetes/pkg/kubelet/cm/cpumanager/state"
	"k8s.io/kubernetes/pkg/kubelet/cm/cpumanager/topology"
	"k8s.io/kubernetes/pkg/kubelet/cm/topologymanager"
	"k8s.io/kubernetes/pkg/kubelet/cm/topologymanager/bitmask"
	"k8s.io/kubernetes/pkg/kubelet/metrics"
	"k8s.io/utils/cpuset"
)

type CoreSelectPolicy string
type SMTSelectPolicy string

const (
	PolicyHpc      policyName       = "hpc"
	StrictHighPerf CoreSelectPolicy = "StrictHighPerf"
	PreferHighPerf CoreSelectPolicy = "PreferHighPerf"
	AvoidHighPerf  CoreSelectPolicy = "AvoidHighPerf"
	Distributed    SMTSelectPolicy  = "Distributed"
	Packed         SMTSelectPolicy  = "Packed"
)

type hpcPolicy struct {
	// cpu socket topology
	topology *topology.CPUTopology
	// set of CPUs that is not available for exclusive assignment
	reservedCPUs cpuset.CPUSet
	// set of CPUs that is only for HPC container
	hpcCPUs cpuset.CPUSet
	// Superset of reservedCPUs. It includes not just the reservedCPUs themselves,
	// but also any siblings of those reservedCPUs on the same physical die.
	// NOTE: If the reserved set includes full physical CPUs from the beginning
	// (e.g. only reserved pairs of core siblings) this set is expected to be
	// identical to the reserved set.
	reservedPhysicalCPUs cpuset.CPUSet
	// topology manager reference to get container Topology affinity
	affinity topologymanager.Store
	// set of CPUs to reuse across allocations in a pod
	cpusToReuse map[string]cpuset.CPUSet
	// options allow to fine-tune the behaviour of the policy
	options HpcPolicyOptions
}

var _ Policy = &hpcPolicy{}

type cpuAllocateOptions struct {
	selectPolicy  CoreSelectPolicy
	smtPolicy     SMTSelectPolicy
	specifiedCpus cpuset.CPUSet
}

func NewHpcPolicy(topology *topology.CPUTopology, numReservedCPUs int, reservedCPUs cpuset.CPUSet, affinity topologymanager.Store, cpuPolicyOptions map[string]string) (Policy, error) {
	opts, err := NewHpcPolicyOptions(cpuPolicyOptions)
	if err != nil {
		return nil, err
	}
	hpcCPUs, err := ValidateHpcPolicyOptions(opts)
	if err != nil {
		return nil, err
	}

	allCPUs := topology.CPUDetails.CPUs()

	if !hpcCPUs.Intersection(allCPUs).Equals(hpcCPUs) {
		return nil, fmt.Errorf("hpcCPUs:%s isn't involved in all cores", opts.HpcCPUs)
	}
	klog.InfoS("Hpc policy created with configuration", "options", opts)

	policy := &hpcPolicy{
		topology:    topology,
		hpcCPUs:     hpcCPUs,
		options:     opts,
		cpusToReuse: make(map[string]cpuset.CPUSet),
		affinity:    affinity,
	}

	var reserved cpuset.CPUSet
	if reservedCPUs.Size() > 0 {
		reserved = reservedCPUs
	} else {
		reserved, err = policy.takeByTopology(allCPUs, numReservedCPUs, AvoidHighPerf, Packed)
		if err != nil {
			klog.ErrorS(err, "Failed to select reserved cores")
			return nil, err
		}
	}

	if reserved.Size() != numReservedCPUs {
		err := fmt.Errorf("[cpumanager] unable to reserve the required amount of CPUs (size of %s did not equal %d)", reserved, numReservedCPUs)
		return nil, err
	}

	var reservedPhysicalCPUs cpuset.CPUSet
	for _, cpu := range reserved.UnsortedList() {
		core, err := topology.CPUCoreID(cpu)
		if err != nil {
			return nil, fmt.Errorf("[cpumanager] unable to build the reserved physical CPUs from the reserved set: %w", err)
		}
		reservedPhysicalCPUs = reservedPhysicalCPUs.Union(topology.CPUDetails.CPUsInCores(core))
	}

	klog.InfoS("Reserved CPUs not available for exclusive assignment", "reservedSize", reserved.Size(), "reserved", reserved, "reservedPhysicalCPUs", reservedPhysicalCPUs)

	if !reserved.Intersection(policy.hpcCPUs).IsEmpty() {
		klog.Warning("reserved cores overlaped with highperf cores")
	}

	if !reservedPhysicalCPUs.Intersection(policy.hpcCPUs).IsEmpty() {
		klog.Warning("reserved Physicalcores overlaped with highperf cores")
	}

	policy.reservedCPUs = reserved
	policy.reservedPhysicalCPUs = reservedPhysicalCPUs

	return policy, nil
}

func (p *hpcPolicy) Name() string {
	return string(PolicyHpc)
}

func (p *hpcPolicy) Start(s state.State) error {
	if err := p.validateState(s); err != nil {
		klog.ErrorS(err, "Hpc policy invalid state, please drain node and remove policy state file")
		return err
	}
	klog.InfoS("Hpc policy: Start")
	return nil
}

func (p *hpcPolicy) Allocate(s state.State, pod *v1.Pod, container *v1.Container) (rerr error) {

	numCPUs := p.guaranteedCPUs(pod, container)
	if numCPUs == 0 {
		// container belongs in the shared pool (nothing to do; use default cpuset)
		return nil
	}

	var allocOpts cpuAllocateOptions

	if specifyCPUsArguement, exists := pod.Annotations["cpu-manager-specify-cpus"]; exists {
		specifyCpus, err := cpuset.Parse(specifyCPUsArguement)
		if err != nil {
			return fmt.Errorf("[cpumanager] unable to parse cpu-manager-specify-cpus:%s", specifyCpus)
		}
		if specifyCpus.Size() != numCPUs {
			return fmt.Errorf("[cpumanager] specified cpus's number not equal to request guranteed cpus")
		}
		allocOpts.specifiedCpus = specifyCpus
	}

	selectPolicy := AvoidHighPerf
	if cpuPolicyOpts, exists := pod.Annotations["cpu-manager-hpcCoreSelect-policy"]; exists {
		switch CoreSelectPolicy(cpuPolicyOpts) {

		case StrictHighPerf:
			selectPolicy = StrictHighPerf

		case PreferHighPerf:
			selectPolicy = PreferHighPerf

		case AvoidHighPerf:
			selectPolicy = AvoidHighPerf

		default:
			return fmt.Errorf("[cpumanager] unable to anylazy pod:%s's Annotations:cpu-manager-hpcCoreSelect-policy=%s", string(pod.UID), cpuPolicyOpts)

		}
	}

	smtPolicy := Packed
	if smtPolicyOpts, exists := pod.Annotations["cpu-manager-smtCoreSelect-policy"]; exists {
		switch SMTSelectPolicy(smtPolicyOpts) {

		case Distributed:
			smtPolicy = Distributed

		case Packed:
			smtPolicy = Packed

		default:
			return fmt.Errorf("[cpumanager] unable to anylazy pod:%s's Annotations:cpu-manager-smtCoreSelect-policy=%s", string(pod.UID), smtPolicyOpts)
		}
	}

	allocOpts.selectPolicy = selectPolicy
	allocOpts.smtPolicy = smtPolicy
	klog.InfoS("Hpc policy: Allocate", "pod", klog.KObj(pod), "containerName", container.Name)
	metrics.CPUManagerPinningRequestsTotal.Inc()

	defer func() {
		if rerr != nil {
			metrics.CPUManagerPinningErrorsTotal.Inc()
		}
	}()

	if cpuset, ok := s.GetCPUSet(string(pod.UID), container.Name); ok {
		p.updateCPUsToReuse(pod, container, cpuset)
		klog.InfoS("Hpc policy: container already present in state, skipping", "pod", klog.KObj(pod), "containerName", container.Name)
		return nil
	}

	hint := p.affinity.GetAffinity(string(pod.UID), container.Name)
	klog.InfoS("Topology Affinity", "pod", klog.KObj(pod), "containerName", container.Name, "affinity", hint)

	cpuset, err := p.allocateCPUs(s, numCPUs, hint.NUMANodeAffinity, p.cpusToReuse[string(pod.UID)], &allocOpts)
	if err != nil {
		klog.ErrorS(err, "Unable to allocate CPUs", "pod", klog.KObj(pod), "containerName", container.Name, "numCPUs", numCPUs, "allocOpts", allocOpts)
		return err
	}
	s.SetCPUSet(string(pod.UID), container.Name, cpuset)
	p.updateCPUsToReuse(pod, container, cpuset)

	if p.options.CoresIndexInjection {
		klog.Infof("cpu-exclusive-cpusalloc -- %s", cpuset.String())
		if pod.Annotations == nil {
			pod.Annotations = make(map[string]string)
		}
		pod.Annotations["cpu-exclusive-cpusalloc"] = cpuset.String()
	}

	return nil
}

func (p *hpcPolicy) RemoveContainer(s state.State, podUID string, containerName string) error {
	klog.InfoS("Hpc policy: RemoveContainer", "podUID", podUID, "containerName", containerName)
	cpusInUse := getAssignedCPUsOfSiblings(s, podUID, containerName)
	if toRelease, ok := s.GetCPUSet(podUID, containerName); ok {
		s.Delete(podUID, containerName)
		// Mutate the shared pool, adding released cpus.
		toRelease = toRelease.Difference(cpusInUse)
		s.SetDefaultCPUSet(s.GetDefaultCPUSet().Union(toRelease))
	}
	return nil
}

func (p *hpcPolicy) GetTopologyHints(s state.State, pod *v1.Pod, container *v1.Container) map[string][]topologymanager.TopologyHint {
	requested := p.guaranteedCPUs(pod, container)

	if requested == 0 {
		return nil
	}

	if allocated, exists := s.GetCPUSet(string(pod.UID), container.Name); exists {

		if allocated.Size() != requested {
			klog.ErrorS(nil, "CPUs already allocated to container with different number than request", "pod", klog.KObj(pod), "containerName", container.Name, "requestedSize", requested, "allocatedSize", allocated.Size())
			return map[string][]topologymanager.TopologyHint{
				string(v1.ResourceCPU): {},
			}
		}

		klog.InfoS("Regenerating TopologyHints for CPUs already allocated", "pod", klog.KObj(pod), "containerName", container.Name)
		return map[string][]topologymanager.TopologyHint{
			string(v1.ResourceCPU): p.generateCPUTopologyHints(allocated, cpuset.CPUSet{}, requested),
		}
	}
	available := p.GetAvailableCPUs(s)

	reusable := p.cpusToReuse[string(pod.UID)]

	// Generate hints.
	cpuHints := p.generateCPUTopologyHints(available, reusable, requested)
	klog.InfoS("TopologyHints generated", "pod", klog.KObj(pod), "containerName", container.Name, "cpuHints", cpuHints)

	return map[string][]topologymanager.TopologyHint{
		string(v1.ResourceCPU): cpuHints,
	}
}

func (p *hpcPolicy) GetPodTopologyHints(s state.State, pod *v1.Pod) map[string][]topologymanager.TopologyHint {
	// Get a count of how many guaranteed CPUs have been requested by Pod.
	requested := p.podGuaranteedCPUs(pod)

	// Number of required CPUs is not an integer or a pod is not part of the Guaranteed QoS class.
	// It will be treated by the TopologyManager as having no preference and cause it to ignore this
	// resource when considering pod alignment.
	// In terms of hints, this is equal to: TopologyHints[NUMANodeAffinity: nil, Preferred: true].
	if requested == 0 {
		return nil
	}

	assignedCPUs := cpuset.New()
	for _, container := range append(pod.Spec.InitContainers, pod.Spec.Containers...) {
		requestedByContainer := p.guaranteedCPUs(pod, &container)
		// Short circuit to regenerate the same hints if there are already
		// guaranteed CPUs allocated to the Container. This might happen after a
		// kubelet restart, for example.
		if allocated, exists := s.GetCPUSet(string(pod.UID), container.Name); exists {
			if allocated.Size() != requestedByContainer {
				klog.ErrorS(nil, "CPUs already allocated to container with different number than request", "pod", klog.KObj(pod), "containerName", container.Name, "allocatedSize", requested, "requestedByContainer", requestedByContainer, "allocatedSize", allocated.Size())
				// An empty list of hints will be treated as a preference that cannot be satisfied.
				// In definition of hints this is equal to: TopologyHint[NUMANodeAffinity: nil, Preferred: false].
				// For all but the best-effort policy, the Topology Manager will throw a pod-admission error.
				return map[string][]topologymanager.TopologyHint{
					string(v1.ResourceCPU): {},
				}
			}
			// A set of CPUs already assigned to containers in this pod
			assignedCPUs = assignedCPUs.Union(allocated)
		}
	}
	if assignedCPUs.Size() == requested {
		klog.InfoS("Regenerating TopologyHints for CPUs already allocated", "pod", klog.KObj(pod))
		return map[string][]topologymanager.TopologyHint{
			string(v1.ResourceCPU): p.generateCPUTopologyHints(assignedCPUs, cpuset.CPUSet{}, requested),
		}
	}

	// Get a list of available CPUs.
	available := p.GetAvailableCPUs(s)

	// Get a list of reusable CPUs (e.g. CPUs reused from initContainers).
	// It should be an empty CPUSet for a newly created pod.
	reusable := p.cpusToReuse[string(pod.UID)]

	// Ensure any CPUs already assigned to containers in this pod are included as part of the hint generation.
	reusable = reusable.Union(assignedCPUs)

	// Generate hints.
	cpuHints := p.generateCPUTopologyHints(available, reusable, requested)
	klog.InfoS("TopologyHints generated", "pod", klog.KObj(pod), "cpuHints", cpuHints)

	return map[string][]topologymanager.TopologyHint{
		string(v1.ResourceCPU): cpuHints,
	}
}

func (p *hpcPolicy) GetAllocatableCPUs(m state.State) cpuset.CPUSet {
	return p.topology.CPUDetails.CPUs().Difference(p.reservedCPUs)
}

func (p *hpcPolicy) takeByTopology(availableCPUs cpuset.CPUSet, numCPUs int, selectPolicy CoreSelectPolicy, smtPolicy SMTSelectPolicy) (cpuset.CPUSet, error) {
	intersection := availableCPUs.Intersection(p.hpcCPUs)
	klog.Infof("cpuCore select policy:%s", string(selectPolicy))
	switch selectPolicy {

	case StrictHighPerf:
		return takeByTopologyOptional(p.topology, intersection, numCPUs, smtPolicy)

	case PreferHighPerf:
		result := cpuset.New()
		noneIntersection := availableCPUs.Difference(intersection)
		firstPickSize := numCPUs

		if intersection.Size() < numCPUs {
			firstPickSize = intersection.Size()
		}

		firstPick, err := takeByTopologyOptional(p.topology, intersection, firstPickSize, smtPolicy)
		if err != nil {
			return result, err
		}

		result = result.Union(firstPick)
		secondPick, err := takeByTopologyOptional(p.topology, noneIntersection, numCPUs-firstPickSize, smtPolicy)

		if err != nil {
			return result, err
		}

		result = result.Union(secondPick)

		klog.InfoS("enter branch of PreferHighPerf", "allocatableHpcCpus", intersection.String(), "firstPick", firstPick.String(), "secondPick", secondPick.String())

		return result, nil

	case AvoidHighPerf:
		firstPickSize := numCPUs
		result := cpuset.New()
		noneIntersection := availableCPUs.Difference(intersection)

		if noneIntersection.Size() < numCPUs {
			firstPickSize = noneIntersection.Size()
		}

		firstPick, err := takeByTopologyOptional(p.topology, noneIntersection, firstPickSize, smtPolicy)

		if err != nil {
			return result, err
		}

		result = result.Union(firstPick)
		secondPick, err := takeByTopologyOptional(p.topology, intersection, numCPUs-firstPickSize, smtPolicy)

		if err != nil {
			return result, err
		}

		result = result.Union(secondPick)

		klog.InfoS("enter branch of AvoidHighPerf", "allocatableHpcCpus", intersection.String(), "firstPick", firstPick.String(), "secondPick", secondPick.String())

		return result, nil

	default:
		return cpuset.CPUSet{}, fmt.Errorf("unknown coreSelect policy: \"%s\"", selectPolicy)
	}
}

func (p *hpcPolicy) validateState(s state.State) error {
	tmpAssignments := s.GetCPUAssignments()
	tmpDefaultCPUset := s.GetDefaultCPUSet()

	// Default cpuset cannot be empty when assignments exist
	if tmpDefaultCPUset.IsEmpty() {
		if len(tmpAssignments) != 0 {
			return fmt.Errorf("default cpuset cannot be empty")
		}
		// state is empty initialize
		allCPUs := p.topology.CPUDetails.CPUs()
		s.SetDefaultCPUSet(allCPUs)
		return nil
	}

	// State has already been initialized from file (is not empty)
	// 1. Check if the reserved cpuset is not part of default cpuset because:
	// - kube/system reserved have changed (increased) - may lead to some containers not being able to start
	// - user tampered with file
	if !p.reservedCPUs.Intersection(tmpDefaultCPUset).Equals(p.reservedCPUs) {
		return fmt.Errorf("not all reserved cpus: \"%s\" are present in defaultCpuSet: \"%s\"",
			p.reservedCPUs.String(), tmpDefaultCPUset.String())
	}

	// 2. Check if state for static policy is consistent
	for pod := range tmpAssignments {
		for container, cset := range tmpAssignments[pod] {
			// None of the cpu in DEFAULT cset should be in s.assignments
			if !tmpDefaultCPUset.Intersection(cset).IsEmpty() {
				return fmt.Errorf("pod: %s, container: %s cpuset: \"%s\" overlaps with default cpuset \"%s\"",
					pod, container, cset.String(), tmpDefaultCPUset.String())
			}
		}
	}

	// 3. It's possible that the set of available CPUs has changed since
	// the state was written. This can be due to for example
	// offlining a CPU when kubelet is not running. If this happens,
	// CPU manager will run into trouble when later it tries to
	// assign non-existent CPUs to containers. Validate that the
	// topology that was received during CPU manager startup matches with
	// the set of CPUs stored in the state.
	totalKnownCPUs := tmpDefaultCPUset.Clone()
	tmpCPUSets := []cpuset.CPUSet{}
	for pod := range tmpAssignments {
		for _, cset := range tmpAssignments[pod] {
			tmpCPUSets = append(tmpCPUSets, cset)
		}
	}
	totalKnownCPUs = totalKnownCPUs.Union(tmpCPUSets...)
	if !totalKnownCPUs.Equals(p.topology.CPUDetails.CPUs()) {
		return fmt.Errorf("current set of available CPUs \"%s\" doesn't match with CPUs in state \"%s\"",
			p.topology.CPUDetails.CPUs().String(), totalKnownCPUs.String())
	}

	return nil
}

func (p *hpcPolicy) guaranteedCPUs(pod *v1.Pod, container *v1.Container) int {
	if v1qos.GetPodQOS(pod) != v1.PodQOSGuaranteed {
		return 0
	}
	cpuQuantity := container.Resources.Requests[v1.ResourceCPU]
	// In-place pod resize feature makes Container.Resources field mutable for CPU & memory.
	// AllocatedResources holds the value of Container.Resources.Requests when the pod was admitted.
	// We should return this value because this is what kubelet agreed to allocate for the container
	// and the value configured with runtime.
	if utilfeature.DefaultFeatureGate.Enabled(features.InPlacePodVerticalScaling) {
		if cs, ok := podutil.GetContainerStatus(pod.Status.ContainerStatuses, container.Name); ok {
			cpuQuantity = cs.AllocatedResources[v1.ResourceCPU]
		}
	}
	if cpuQuantity.Value()*1000 != cpuQuantity.MilliValue() {
		return 0
	}
	// Safe downcast to do for all systems with < 2.1 billion CPUs.
	// Per the language spec, `int` is guaranteed to be at least 32 bits wide.
	// https://golang.org/ref/spec#Numeric_types
	return int(cpuQuantity.Value())
}

func (p *hpcPolicy) GetAvailableCPUs(s state.State) cpuset.CPUSet {
	return s.GetDefaultCPUSet().Difference(p.reservedCPUs)
}

func (p *hpcPolicy) GetAvailablePhysicalCPUs(s state.State) cpuset.CPUSet {
	return s.GetDefaultCPUSet().Difference(p.reservedPhysicalCPUs)
}

func (p *hpcPolicy) allocateCPUs(s state.State, numCPUs int, numaAffinity bitmask.BitMask, reusableCPUs cpuset.CPUSet, allocOpts *cpuAllocateOptions) (cpuset.CPUSet, error) {
	allocatableCPUs := p.GetAvailableCPUs(s).Union(reusableCPUs)
	klog.InfoS("AllocateCPUs", "allocatableCpus", allocatableCPUs.String(), "numCPUs", numCPUs, "socket", numaAffinity)
	if !allocOpts.specifiedCpus.IsEmpty() {
		if !allocOpts.specifiedCpus.IsSubsetOf(allocatableCPUs) {
			return cpuset.CPUSet{}, fmt.Errorf("specified cpus is not subset of allocatable cpus")
		}
		s.SetDefaultCPUSet(s.GetDefaultCPUSet().Difference(allocOpts.specifiedCpus))
		klog.InfoS("AllocateCPUs", "result", allocOpts.specifiedCpus)
		return allocOpts.specifiedCpus, nil
	}
	result, err := p.takeByTopology(allocatableCPUs, numCPUs, allocOpts.selectPolicy, allocOpts.smtPolicy)
	if err != nil {
		return cpuset.New(), err
	}

	s.SetDefaultCPUSet(s.GetDefaultCPUSet().Difference(result))

	klog.InfoS("AllocateCPUs", "result", result)
	return result, nil

}

func (p *hpcPolicy) generateCPUTopologyHints(availableCPUs cpuset.CPUSet, reusableCPUs cpuset.CPUSet, request int) []topologymanager.TopologyHint {
	// Initialize minAffinitySize to include all NUMA Nodes.
	minAffinitySize := p.topology.CPUDetails.NUMANodes().Size()

	// Iterate through all combinations of numa nodes bitmask and build hints from them.
	hints := []topologymanager.TopologyHint{}
	bitmask.IterateBitMasks(p.topology.CPUDetails.NUMANodes().List(), func(mask bitmask.BitMask) {
		// First, update minAffinitySize for the current request size.
		cpusInMask := p.topology.CPUDetails.CPUsInNUMANodes(mask.GetBits()...).Size()
		if cpusInMask >= request && mask.Count() < minAffinitySize {
			minAffinitySize = mask.Count()
		}

		// Then check to see if we have enough CPUs available on the current
		// numa node bitmask to satisfy the CPU request.
		numMatching := 0
		for _, c := range reusableCPUs.List() {
			// Disregard this mask if its NUMANode isn't part of it.
			if !mask.IsSet(p.topology.CPUDetails[c].NUMANodeID) {
				return
			}
			numMatching++
		}

		// Finally, check to see if enough available CPUs remain on the current
		// NUMA node combination to satisfy the CPU request.
		for _, c := range availableCPUs.List() {
			if mask.IsSet(p.topology.CPUDetails[c].NUMANodeID) {
				numMatching++
			}
		}

		// If they don't, then move onto the next combination.
		if numMatching < request {
			return
		}

		// Otherwise, create a new hint from the numa node bitmask and add it to the
		// list of hints.  We set all hint preferences to 'false' on the first
		// pass through.
		hints = append(hints, topologymanager.TopologyHint{
			NUMANodeAffinity: mask,
			Preferred:        false,
		})
	})

	for i := range hints {
		if hints[i].NUMANodeAffinity.Count() == minAffinitySize {
			hints[i].Preferred = true
		}
	}

	return hints
}

func (p *hpcPolicy) podGuaranteedCPUs(pod *v1.Pod) int {
	// The maximum of requested CPUs by init containers.
	requestedByInitContainers := 0
	for _, container := range pod.Spec.InitContainers {
		if _, ok := container.Resources.Requests[v1.ResourceCPU]; !ok {
			continue
		}
		requestedCPU := p.guaranteedCPUs(pod, &container)
		if requestedCPU > requestedByInitContainers {
			requestedByInitContainers = requestedCPU
		}
	}
	// The sum of requested CPUs by app containers.
	requestedByAppContainers := 0
	for _, container := range pod.Spec.Containers {
		if _, ok := container.Resources.Requests[v1.ResourceCPU]; !ok {
			continue
		}
		requestedByAppContainers += p.guaranteedCPUs(pod, &container)
	}

	if requestedByInitContainers > requestedByAppContainers {
		return requestedByInitContainers
	}
	return requestedByAppContainers
}

func (p *hpcPolicy) updateCPUsToReuse(pod *v1.Pod, container *v1.Container, cset cpuset.CPUSet) {
	// If pod entries to m.cpusToReuse other than the current pod exist, delete them.
	for podUID := range p.cpusToReuse {
		if podUID != string(pod.UID) {
			delete(p.cpusToReuse, podUID)
		}
	}
	// If no cpuset exists for cpusToReuse by this pod yet, create one.
	if _, ok := p.cpusToReuse[string(pod.UID)]; !ok {
		p.cpusToReuse[string(pod.UID)] = cpuset.New()
	}
	// Check if the container is an init container.
	// If so, add its cpuset to the cpuset of reusable CPUs for any new allocations.
	for _, initContainer := range pod.Spec.InitContainers {
		if container.Name == initContainer.Name {
			p.cpusToReuse[string(pod.UID)] = p.cpusToReuse[string(pod.UID)].Union(cset)
			return
		}
	}
	// Otherwise it is an app container.
	// Remove its cpuset from the cpuset of reusable CPUs for any new allocations.
	p.cpusToReuse[string(pod.UID)] = p.cpusToReuse[string(pod.UID)].Difference(cset)
}
