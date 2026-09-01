// @vitest-environment jsdom

import { cleanup, fireEvent, render, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Hero } from './Hero'

vi.mock('./HeroBackdropSwirl', () => ({
  HeroBackdropSwirl: () => null,
}))

vi.mock('./MediaFrame', () => ({
  MediaFrame: () => null,
}))

describe('Homebrew command', () => {
  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
  })

  it('confirms a successful copy', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    vi.stubGlobal('navigator', { clipboard: { writeText } })
    const { getByRole } = render(<Hero />)
    const button = getByRole('button', { name: 'Copy the Homebrew install command' })

    fireEvent.click(button)

    await waitFor(() => expect(button.getAttribute('data-state')).toBe('copied'))
    expect(writeText).toHaveBeenCalledWith('brew install --cask rydersel/tap/candela')
    expect(getByRole('status').textContent).toBe('copied')
  })

  it('reports when the browser refuses clipboard access', async () => {
    vi.stubGlobal('navigator', {
      clipboard: { writeText: vi.fn().mockRejectedValue(new Error('denied')) },
    })
    const { getByRole } = render(<Hero />)
    const button = getByRole('button', { name: 'Copy the Homebrew install command' })

    fireEvent.click(button)

    await waitFor(() => expect(button.getAttribute('data-state')).toBe('failed'))
    expect(getByRole('status').textContent).toBe('Copy failed. Select manually.')
  })

  it('reports when the clipboard API is unavailable', async () => {
    vi.stubGlobal('navigator', {})
    const { getByRole } = render(<Hero />)
    const button = getByRole('button', { name: 'Copy the Homebrew install command' })

    fireEvent.click(button)

    await waitFor(() => expect(button.getAttribute('data-state')).toBe('failed'))
    expect(getByRole('status').textContent).toBe('Copy failed. Select manually.')
  })
})
