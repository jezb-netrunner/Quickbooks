import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { keys } from '@/lib/queryKeys'
import {
  addMember,
  fetchAssignments,
  fetchMembers,
  removeMember,
  renameFirm,
  updateMember,
  type AddMemberInput,
  type UpdateMemberInput,
} from './api'

export function useMembers(firmId: string) {
  return useQuery({ queryKey: keys.members(firmId), queryFn: () => fetchMembers(firmId) })
}

export function useAssignments(firmId: string) {
  return useQuery({ queryKey: keys.assignments(firmId), queryFn: () => fetchAssignments(firmId) })
}

export function useAddMember(firmId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Omit<AddMemberInput, 'firmId'>) => addMember({ firmId, ...input }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: keys.members(firmId) })
      qc.invalidateQueries({ queryKey: keys.assignments(firmId) })
    },
  })
}

export function useUpdateMember(firmId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: UpdateMemberInput) => updateMember(input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: keys.members(firmId) })
      qc.invalidateQueries({ queryKey: keys.assignments(firmId) })
    },
  })
}

export function useRemoveMember(firmId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (membershipId: string) => removeMember(membershipId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: keys.members(firmId) })
      qc.invalidateQueries({ queryKey: keys.assignments(firmId) })
    },
  })
}

export function useRenameFirm(firmId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (name: string) => renameFirm(firmId, name),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.memberships }),
  })
}
